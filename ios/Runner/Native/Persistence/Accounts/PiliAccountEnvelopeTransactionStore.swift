import Foundation

enum PiliAccountShadowTransactionError: Error, Sendable, Equatable {
  case operationInProgress, shadowUnavailable, unknownRecordKey, staleGeneration
  case duplicateRecordKey, invalidInstall
}

struct PiliAccountShadowCookieSave: Sendable, Equatable {
  let fields: [String]
  let representation: PiliNativeCookieFieldRepresentation
  let location: PiliOrderedCookieResponseLocation
  let nowMicroseconds: Int64
}

/// Complete login record appended by the install transaction. The transaction
/// mints the durable identity itself; callers cannot supply one.
struct PiliAccountShadowInstall: Sendable, Equatable {
  let storageKeyUnits: PiliCookieUTF16
  let mid: Int64
  let generation: Int64
  let accessKeyUnits: PiliCookieUTF16?
  let refreshTokenUnits: PiliCookieUTF16?
  let persistedPurposes: [PiliAccountPurpose]
  let activated: Bool
  let jar: PiliOrderedCookieArchive
}

struct PiliAccountShadowIdentityReceipt: Sendable, Equatable {
  /// Nil when the envelope already carried identities (no publication).
  let transactionID: UUID?
  let adopted: Int
  let nativeWritesAllowed: Bool
  let authoritySwitchAllowed: Bool
}

struct PiliAccountShadowTransactionReceipt: Sendable, Equatable {
  let transactionID: UUID
  let record: Int
  let nativeWritesAllowed: Bool
  let authoritySwitchAllowed: Bool
}

/// Durable single-account transaction over the capture-local shadow. It mutates
/// one exact record (ordered jar, temporary selection, credentials, activated)
/// through production values, revalidates the whole envelope with the shared
/// cumulative ledger and only then publishes a new immutable candidate through
/// the vault pointer.
///
/// This is not an authority handoff: generations stay capture-local, the
/// revision is not renumbered and every receipt states both gates false.
actor PiliAccountEnvelopeTransactionStore {
  private let vault: PiliAccountEnvelopeStagingStore
  private let codec: PiliAccountLiveMemoryShadowCodec
  private var reducer: PiliNativeOrderedCookieReducer
  private var operationInProgress = false
  var nativeWritesAllowed: Bool { false }
  var authoritySwitchAllowed: Bool { false }

  init(vault: PiliAccountEnvelopeStagingStore,
       limits: PiliOrderedCookieArchiveLimits = .standard) {
    self.vault = vault
    codec = PiliAccountLiveMemoryShadowCodec(limits: limits)
    reducer = PiliNativeOrderedCookieReducer(limits: limits)
  }

  func applyCookieSave(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                       _ save: PiliAccountShadowCookieSave) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      let jar = try self.reducer.save(current.records[index].jar, fields: save.fields,
                                      representation: save.representation, location: save.location,
                                      nowMicroseconds: save.nowMicroseconds)
      return self.replaceJar(current, index: index, jar: jar)
    }
  }

  func applyCookieDelete(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                         host: String, withDomainSharedCookie: Bool) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      let jar = try self.reducer.delete(current.records[index].jar, host: host,
                                        withDomainSharedCookie: withDomainSharedCookie)
      return self.replaceJar(current, index: index, jar: jar)
    }
  }

  func applyCookieDeleteAll(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      let jar = try self.reducer.deleteAll(current.records[index].jar)
      return self.replaceJar(current, index: index, jar: jar)
    }
  }

  /// Temporary selection only changes the effective slot; persisted purposes
  /// and every other record stay untouched. History follows the actual source
  /// policy: a login heartbeat uses its own slot, otherwise main.
  func applyTemporarySelection(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                               purpose: PiliAccountPurpose) async throws
    -> PiliAccountShadowTransactionReceipt {
    // The source order is fixed: main, heartbeat, recommend, video.
    let slot = slotIndex(purpose)
    return try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      var selections = current.selections
      selections[slot] = current.records[index].record
      let heartbeat = selections[1]
      let history = current.records[heartbeat].isLogin ? heartbeat : selections[0]
      return self.replace(current, selections: selections, history: history)
    }
  }

  /// Durable persistent-purpose change across at most two login records.
  ///
  /// Mirrors the Dart `Accounts.set` shape: the selected record gains the
  /// purpose (idempotent, appended in Dart insertion order), the optional
  /// previous holder loses it, the slot points at the selected record and
  /// history is derived with the existing policy. Only persistedPurposes,
  /// selections and history may change; jars, order, generations and the
  /// capture-local revision stay untouched.
  func applyPurposeChange(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                          purpose: PiliAccountPurpose,
                          previousKeyUnits: PiliCookieUTF16?,
                          previousExpectedGeneration: Int64?) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      var records = current.records
      let selected = records[index]
      if !selected.persistedPurposes.contains(purpose) {
        records[index] = Self.replacingPurposes(
          selected, purposes: selected.persistedPurposes + [purpose])
      }
      if let previousKeyUnits {
        guard let previousExpectedGeneration else {
          throw PiliAccountShadowTransactionError.staleGeneration
        }
        guard let previousIndex = current.records.firstIndex(where: {
          $0.record > 0 && $0.storageKeyUnits == previousKeyUnits
        }) else {
          throw PiliAccountShadowTransactionError.unknownRecordKey
        }
        let previous = records[previousIndex]
        guard previous.generation == previousExpectedGeneration, previous.isLogin else {
          throw PiliAccountShadowTransactionError.staleGeneration
        }
        if previousIndex != index, previous.persistedPurposes.contains(purpose) {
          records[previousIndex] = Self.replacingPurposes(
            previous, purposes: previous.persistedPurposes.filter { $0 != purpose })
        }
      }
      var selections = current.selections
      selections[slotIndex(purpose)] = records[index].record
      let heartbeat = selections[1]
      let history = records[heartbeat].isLogin ? heartbeat : selections[0]
      return self.replace(current, records: records, selections: selections, history: history)
    }
  }

  func applyCredentials(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                        accessKeyUnits: PiliCookieUTF16?, refreshTokenUnits: PiliCookieUTF16?) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      let record = current.records[index]
      var records = current.records
      records[index] = PiliAccountLiveMemoryRecord(
        record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
        mid: record.mid, isLogin: record.isLogin, accessKeyUnits: accessKeyUnits,
        refreshTokenUnits: refreshTokenUnits, persistedPurposes: record.persistedPurposes,
        activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
      return self.replace(current, records: records)
    }
  }

  func applyActivated(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                      activated: Bool) async throws -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      let record = current.records[index]
      var records = current.records
      records[index] = PiliAccountLiveMemoryRecord(
        record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
        mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
        refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
        activated: activated, jar: record.jar, durableIdentity: record.durableIdentity)
      return self.replace(current, records: records)
    }
  }

  /// Upgrades a schema-2 envelope to schema 3 by minting one persisted identity
  /// per login record. Already-adopted envelopes are a no-op receipt that does
  /// not publish. Identities are minted exactly once here; nothing derives them
  /// from MID, storage key or runtime generation, and nothing authorizes with
  /// them.
  func adoptMissingIdentities() async throws -> PiliAccountShadowIdentityReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 2 else {
      return .init(transactionID: nil, adopted: 0,
                   nativeWritesAllowed: false, authoritySwitchAllowed: false)
    }
    var records = current.records
    var identities = Set<PiliCookieUTF16>()
    for record in records {
      if let identity = record.durableIdentity { identities.insert(identity) }
    }
    var adopted = 0
    for index in records.indices where index > 0 {
      let identity = Self.mintIdentity(excluding: identities)
      identities.insert(identity)
      records[index] = Self.replacingIdentity(records[index], identity: identity)
      adopted += 1
    }
    let candidate = replace(current, records: records, schemaVersion: 3)
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await vault.importShadow(codec.encode(candidate),
                                                   expectedTransactionID: snapshot.transactionID)
    return .init(transactionID: publication.transactionID, adopted: adopted,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Appends one complete login record to an adopted (schema-3) envelope. The
  /// transaction mints the record identity and appends the matching stored/
  /// owner order entries; selections, history, anonymous and every existing
  /// record stay untouched.
  func applyInstall(_ install: PiliAccountShadowInstall) async throws
    -> PiliAccountShadowTransactionReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    // Install is append-only on adopted envelopes; a schema-2 envelope must be
    // adopted first so no existing record changes shape silently.
    guard current.schemaVersion == 3,
          !install.storageKeyUnits.units.isEmpty,
          install.generation > 0,
          Set(install.persistedPurposes).count == install.persistedPurposes.count,
          current.records.count + 1 <= 256 else {
      throw PiliAccountShadowTransactionError.invalidInstall
    }
    guard !current.records.contains(where: {
      $0.record > 0 && $0.storageKeyUnits == install.storageKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.duplicateRecordKey
    }
    guard !current.records.contains(where: { $0.generation == install.generation }) else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    var identities = Set<PiliCookieUTF16>()
    for record in current.records {
      if let identity = record.durableIdentity { identities.insert(identity) }
    }
    let newIndex = current.records.count
    let record = PiliAccountLiveMemoryRecord(
      record: newIndex, generation: install.generation,
      storageKeyUnits: install.storageKeyUnits, mid: install.mid, isLogin: true,
      accessKeyUnits: install.accessKeyUnits, refreshTokenUnits: install.refreshTokenUnits,
      persistedPurposes: install.persistedPurposes, activated: install.activated,
      jar: install.jar, durableIdentity: Self.mintIdentity(excluding: identities))
    let order = PiliAccountLiveMemoryOrderEntry(
      keyUnits: install.storageKeyUnits, record: newIndex)
    let candidate = replace(current,
      records: current.records + [record],
      storedOrder: current.storedOrder + [order],
      ownerOrder: current.ownerOrder + [order])
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await vault.importShadow(codec.encode(candidate),
                                                   expectedTransactionID: snapshot.transactionID)
    return .init(transactionID: publication.transactionID, record: newIndex,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  private static func mintIdentity(excluding existing: Set<PiliCookieUTF16>) -> PiliCookieUTF16 {
    while true {
      let candidate = PiliCookieUTF16(units: Array(UUID().uuidString.lowercased().utf16))
      if !existing.contains(candidate) { return candidate }
    }
  }

  private func transaction(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                           _ transform: (PiliAccountLiveMemoryShadow, Int) throws
                             -> PiliAccountLiveMemoryShadow) async throws
    -> PiliAccountShadowTransactionReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard let index = current.records.firstIndex(where: {
      $0.record > 0 && $0.storageKeyUnits == recordKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.unknownRecordKey
    }
    let record = current.records[index]
    guard record.generation == expectedGeneration, record.isLogin else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    let candidate = try transform(current, index)
    // The complete candidate must still fit the shared cumulative ledger.
    _ = try candidate.validated(limits: codec.limits)
    // The wrapper gate cannot fence other callers of the shared vault. Publish
    // only if the exact pointer used for this transform is still current; the
    // vault owns comparison and publication under one operation fence.
    let publication = try await vault.importShadow(codec.encode(candidate),
                                                   expectedTransactionID: snapshot.transactionID)
    return .init(transactionID: publication.transactionID, record: record.record,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  private func slotIndex(_ purpose: PiliAccountPurpose) -> Int {
    // The source order is fixed: main, heartbeat, recommend, video.
    switch purpose {
    case .main: return 0
    case .heartbeat: return 1
    case .recommend: return 2
    case .video: return 3
    }
  }

  private static func replacingPurposes(
    _ record: PiliAccountLiveMemoryRecord, purposes: [PiliAccountPurpose]
  ) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: purposes,
      activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
  }

  private static func replacingIdentity(
    _ record: PiliAccountLiveMemoryRecord, identity: PiliCookieUTF16
  ) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: record.jar, durableIdentity: identity)
  }

  private func replaceJar(_ current: PiliAccountLiveMemoryShadow, index: Int,
                          jar: PiliOrderedCookieArchive) -> PiliAccountLiveMemoryShadow {
    let record = current.records[index]
    var records = current.records
    records[index] = PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: jar, durableIdentity: record.durableIdentity)
    return replace(current, records: records)
  }

  private func replace(_ current: PiliAccountLiveMemoryShadow,
                       records: [PiliAccountLiveMemoryRecord]? = nil,
                       storedOrder: [PiliAccountLiveMemoryOrderEntry]? = nil,
                       ownerOrder: [PiliAccountLiveMemoryOrderEntry]? = nil,
                       selections: [Int]? = nil,
                       history: Int? = nil,
                       schemaVersion: Int? = nil) -> PiliAccountLiveMemoryShadow {
    PiliAccountLiveMemoryShadow(
      schemaVersion: schemaVersion ?? current.schemaVersion,
      scope: current.scope, identityScope: current.identityScope,
      revision: current.revision, durableIdentityConfigured: current.durableIdentityConfigured,
      durabilityVerified: current.durabilityVerified,
      authoritySwitchAllowed: current.authoritySwitchAllowed,
      nativeWritesAllowed: current.nativeWritesAllowed,
      records: records ?? current.records,
      storedOrder: storedOrder ?? current.storedOrder,
      ownerOrder: ownerOrder ?? current.ownerOrder, selectionPurposes: current.selectionPurposes,
      selections: selections ?? current.selections, history: history ?? current.history)
  }

  private func beginOperation() throws {
    // Actor methods can reenter across awaits; fence the load/transform/publish
    // transaction until its durable publication has finished.
    guard !operationInProgress else {
      throw PiliAccountShadowTransactionError.operationInProgress
    }
    operationInProgress = true
  }
}
