import Foundation

enum PiliAccountShadowTransactionError: Error, Sendable, Equatable {
  case operationInProgress, shadowUnavailable, unknownRecordKey, staleGeneration
  case duplicateRecordKey, invalidInstall
  case invalidDelete, invalidImport
  case invalidBuvid
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

struct PiliAccountShadowImportReceipt: Sendable, Equatable {
  let transactionID: UUID
  let replaced: Int
  let appended: Int
  let nativeWritesAllowed: Bool
  let authoritySwitchAllowed: Bool
}

struct PiliAccountShadowBuvidReceipt: Sendable, Equatable {
  /// Nil when the record already carried buvid3 (idempotent no-op).
  let transactionID: UUID?
  let seeded: Bool
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

  /// Low-level durable purpose move across at most two explicitly named
  /// records. It does NOT scan for other holders and does NOT enforce global
  /// uniqueness: legacy captures (and Dart imports with `preserveTypes:false`)
  /// may hold the same purpose on several records, and only the caller-named
  /// `previousKeyUnits` loses it. Exact preconditions:
  /// - `previousKeyUnits == nil` means "no holder to remove": if another record
  ///   still holds the purpose it keeps it (documented primitive behavior).
  /// - a non-nil previous must name the actual holder; a record that does not
  ///   hold the purpose is left untouched.
  /// - `previousKeyUnits == recordKeyUnits` is an idempotent no-op for removal.
  /// The selected record gains the purpose (idempotent, appended in Dart
  /// insertion order), the slot points at it and history is derived with the
  /// existing policy. Only persistedPurposes, selections and history change;
  /// jars, orders, generations and the capture-local revision stay untouched.
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
    let highWater = records.dropFirst().map(\.generation).max() ?? 0
    let candidate = replace(current, records: records, schemaVersion: 3,
                            generationHighWater: highWater)
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
    // A new generation is only accepted above the persisted monotonic
    // high-water, so a generation removed by delete or replaced by import can
    // never be reused, including after a restart.
    let highWater = current.effectiveGenerationHighWater
    guard install.generation > highWater else {
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
      ownerOrder: current.ownerOrder + [order],
      generationHighWater: max(highWater, install.generation))
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await vault.importShadow(codec.encode(candidate),
                                                   expectedTransactionID: snapshot.transactionID)
    return .init(transactionID: publication.transactionID, record: newIndex,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Deletes one exact login record from an adopted envelope. Records after the
  /// deleted index are renumbered, both orders are removed and renumbered, and
  /// every selection slot follows the Dart delete policy: a slot that pointed
  /// at the deleted record becomes anonymous, later slots shift by one.
  /// History is derived again; remaining record identities are preserved.
  func applyDelete(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64) async throws
    -> PiliAccountShadowTransactionReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 3 else {
      throw PiliAccountShadowTransactionError.invalidDelete
    }
    // Anonymous records carry no storage key, so it can never be matched here.
    guard let index = current.records.firstIndex(where: {
      $0.record > 0 && $0.storageKeyUnits == recordKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.unknownRecordKey
    }
    let deleted = current.records[index]
    guard deleted.generation == expectedGeneration, deleted.isLogin else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    var records: [PiliAccountLiveMemoryRecord] = []
    for (oldIndex, record) in current.records.enumerated() where oldIndex != index {
      let newIndex = oldIndex < index ? oldIndex : oldIndex - 1
      records.append(newIndex == oldIndex ? record : Self.renumbered(record, as: newIndex))
    }
    let storedOrder = current.storedOrder
      .filter { $0.record != index }
      .map { entry in entry.record < index ? entry :
        PiliAccountLiveMemoryOrderEntry(keyUnits: entry.keyUnits, record: entry.record - 1) }
    let ownerOrder = current.ownerOrder
      .filter { $0.record != index }
      .map { entry in entry.record < index ? entry :
        PiliAccountLiveMemoryOrderEntry(keyUnits: entry.keyUnits, record: entry.record - 1) }
    let selections = current.selections.map { slot in
      if slot == index { return 0 }
      return slot > index ? slot - 1 : slot
    }
    let heartbeat = selections[1]
    let history = records[heartbeat].isLogin ? heartbeat : selections[0]
    let candidate = replace(current, records: records, storedOrder: storedOrder,
                            ownerOrder: ownerOrder, selections: selections, history: history)
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await vault.importShadow(codec.encode(candidate),
                                                   expectedTransactionID: snapshot.transactionID)
    return .init(transactionID: publication.transactionID, record: index,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Imports complete login records into an adopted envelope, mirroring Dart
  /// `importCredentials`: an input key that already exists replaces that exact
  /// record in place (identity preserved, generation must be genuinely new), a
  /// new key is appended in input order with a minted identity, and the owner
  /// registry/selections/history are rebuilt exactly like Dart's trailing
  /// `refresh()` (temporary selections cleared). One candidate is published;
  /// any rejection publishes nothing.
  func applyImport(_ entries: [PiliAccountShadowInstall]) async throws
    -> PiliAccountShadowImportReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 3 else {
      throw PiliAccountShadowTransactionError.invalidImport
    }
    guard !entries.isEmpty else { throw PiliAccountShadowTransactionError.invalidImport }
    var entryKeys = Set<PiliCookieUTF16>()
    var entryGenerations = Set<Int64>()
    let highWater = current.effectiveGenerationHighWater
    // Key shape and uniqueness first, so a duplicate input key is always
    // reported as duplicateRecordKey regardless of generation arithmetic.
    for entry in entries {
      guard !entry.storageKeyUnits.units.isEmpty,
            Set(entry.persistedPurposes).count == entry.persistedPurposes.count else {
        throw PiliAccountShadowTransactionError.invalidImport
      }
      guard entryKeys.insert(entry.storageKeyUnits).inserted else {
        throw PiliAccountShadowTransactionError.duplicateRecordKey
      }
    }
    // Every imported generation must be genuinely new (above the persisted
    // monotonic high-water) and unique inside the input, so replacement can
    // never reuse a replaced or historically removed generation.
    for entry in entries {
      guard entry.generation > 0, entry.generation > highWater,
            entryGenerations.insert(entry.generation).inserted else {
        throw PiliAccountShadowTransactionError.staleGeneration
      }
    }
    var records = current.records
    var identities = Set<PiliCookieUTF16>()
    for record in records {
      if let identity = record.durableIdentity { identities.insert(identity) }
    }
    var replaced = 0
    var appended = 0
    var appendedOrder: [PiliAccountLiveMemoryOrderEntry] = []
    for entry in entries {
      if let index = records.firstIndex(where: {
        $0.record > 0 && $0.storageKeyUnits == entry.storageKeyUnits
      }) {
        records[index] = PiliAccountLiveMemoryRecord(
          record: index, generation: entry.generation,
          storageKeyUnits: entry.storageKeyUnits, mid: entry.mid, isLogin: true,
          accessKeyUnits: entry.accessKeyUnits, refreshTokenUnits: entry.refreshTokenUnits,
          persistedPurposes: entry.persistedPurposes, activated: entry.activated,
          jar: entry.jar, durableIdentity: records[index].durableIdentity)
        replaced += 1
        continue
      }
      guard records.count + 1 <= 256 else {
        throw PiliAccountShadowTransactionError.invalidImport
      }
      let newIndex = records.count
      let identity = Self.mintIdentity(excluding: identities)
      identities.insert(identity)
      records.append(PiliAccountLiveMemoryRecord(
        record: newIndex, generation: entry.generation,
        storageKeyUnits: entry.storageKeyUnits, mid: entry.mid, isLogin: true,
        accessKeyUnits: entry.accessKeyUnits, refreshTokenUnits: entry.refreshTokenUnits,
        persistedPurposes: entry.persistedPurposes, activated: entry.activated,
        jar: entry.jar, durableIdentity: identity))
      appendedOrder.append(PiliAccountLiveMemoryOrderEntry(
        keyUnits: entry.storageKeyUnits, record: newIndex))
      appended += 1
    }
    // Dart importCredentials ends in refresh(): a replaced owner is revoked and
    // re-inserted at the end of the owner registry, temporary selections are
    // cleared and every slot is rebuilt from owners/types in that order with
    // the last writer winning. Mirror that observable result exactly.
    var ownerOrder = current.ownerOrder.filter { !entryKeys.contains($0.keyUnits) }
    for entry in entries {
      guard let index = records.firstIndex(where: {
        $0.storageKeyUnits == entry.storageKeyUnits
      }) else {
        throw PiliAccountShadowTransactionError.invalidImport
      }
      ownerOrder.append(PiliAccountLiveMemoryOrderEntry(
        keyUnits: entry.storageKeyUnits, record: records[index].record))
    }
    var selections = [0, 0, 0, 0]
    for orderEntry in ownerOrder {
      for purpose in records[orderEntry.record].persistedPurposes {
        selections[slotIndex(purpose)] = orderEntry.record
      }
    }
    let heartbeat = selections[1]
    let history = records[heartbeat].isLogin ? heartbeat : selections[0]
    let candidate = replace(current, records: records,
      storedOrder: current.storedOrder + appendedOrder,
      ownerOrder: ownerOrder, selections: selections, history: history,
      generationHighWater: max(highWater, entryGenerations.max() ?? highWater))
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await vault.importShadow(codec.encode(candidate),
                                                   expectedTransactionID: snapshot.transactionID)
    return .init(transactionID: publication.transactionID, replaced: replaced, appended: appended,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Maximum caller value accepted before the field is constructed. The raw
  /// Set-Cookie parser ceiling is `maximumValueUnits` (65536) bytes for one
  /// field; 64 units of `"buvid3="`/`"; Domain=.bilibili.com; Path=/"` headroom
  /// stay below it, so this API fails intentionally (`resourceLimit`) instead
  /// of surfacing a parser error. Length and domain are documented in
  /// P05_DURABLE_BUVID_PLAN.md.
  static let buvidMaximumValueUnits =
    PiliOrderedCookieArchiveLimits.standard.maximumValueUnits - 64

  /// Seeds the missing `buvid3` cookie of one exact login record, mirroring
  /// Dart `BiliCookieJar.setBuvid3` (`domainCookies['bilibili.com']['/']
  /// ['buvid3'] ??=`). The value is caller-supplied printable ASCII; the
  /// transaction never mints credentials. An existing buvid3 is an idempotent
  /// no-op that publishes nothing.
  func applyBuvidSeed(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                      valueUnits: PiliCookieUTF16, nowMicroseconds: Int64) async throws
    -> PiliAccountShadowBuvidReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 3 else {
      throw PiliAccountShadowTransactionError.invalidBuvid
    }
    guard let index = current.records.firstIndex(where: {
      $0.record > 0 && $0.storageKeyUnits == recordKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.unknownRecordKey
    }
    let record = current.records[index]
    guard record.generation == expectedGeneration, record.isLogin else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    // Printable ASCII without the field separator and inside the intentional
    // API length ceiling: the value is interpolated into a single Set-Cookie
    // field, so CR/LF/';'/empty values and over-long values fail before any
    // field construction instead of surfacing a parser error.
    guard !valueUnits.units.isEmpty,
          valueUnits.units.allSatisfy({ $0 >= 0x21 && $0 < 0x7F && $0 != 0x3B }) else {
      throw PiliAccountShadowTransactionError.invalidBuvid
    }
    guard valueUnits.units.count <= Self.buvidMaximumValueUnits else {
      throw PiliAccountLiveMemoryShadowError.resourceLimit
    }
    if Self.hasBuvid3(record.jar) {
      return .init(transactionID: nil, seeded: false,
                   nativeWritesAllowed: false, authoritySwitchAllowed: false)
    }
    let value = String(decoding: valueUnits.units, as: UTF16.self)
    let jar = try reducer.save(
      record.jar,
      fields: ["buvid3=\(value); Domain=.bilibili.com; Path=/"],
      representation: .separated,
      location: PiliOrderedCookieResponseLocation(host: "bilibili.com", path: "/"),
      nowMicroseconds: nowMicroseconds)
    let candidate = replaceJar(current, index: index, jar: jar)
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await vault.importShadow(codec.encode(candidate),
                                                   expectedTransactionID: snapshot.transactionID)
    return .init(transactionID: publication.transactionID, seeded: true,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Presence follows the Dart jar map key: the `buvid3` entry inside the
  /// `bilibili.com` domain bucket at path `/` (never the mutable Cookie.name).
  private static func hasBuvid3(_ jar: PiliOrderedCookieArchive) -> Bool {
    let domainKey = PiliCookieUTF16(units: Array("bilibili.com".utf16))
    let pathKey = PiliCookieUTF16(units: Array("/".utf16))
    let nameKey = PiliCookieUTF16(units: Array("buvid3".utf16))
    guard let bucket = jar.domainBuckets.first(where: { $0.keyUnits == domainKey }),
          let path = bucket.paths.first(where: { $0.keyUnits == pathKey }) else {
      return false
    }
    return path.cookies.contains(where: { $0.keyUnits == nameKey })
  }

  private static func renumbered(_ record: PiliAccountLiveMemoryRecord,
                                 as index: Int) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: index, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
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
                       schemaVersion: Int? = nil,
                       generationHighWater: Int64? = nil) -> PiliAccountLiveMemoryShadow {
    let version = schemaVersion ?? current.schemaVersion
    let carried = generationHighWater ?? current.generationHighWater
    // Schema 3 must never lose the monotonic high-water: legacy envelopes that
    // omitted/nulled the field persist the pre-transform effective value on
    // every publication, so deleting the maximum or last login cannot lower
    // the water that later guards reused generations against. Schema 2 keeps
    // its strict nil shape.
    let resolvedHighWater: Int64? = version == 3
      ? max(carried ?? 0, current.effectiveGenerationHighWater)
      : nil
    return PiliAccountLiveMemoryShadow(
      schemaVersion: version,
      scope: current.scope, identityScope: current.identityScope,
      revision: current.revision, durableIdentityConfigured: current.durableIdentityConfigured,
      durabilityVerified: current.durabilityVerified,
      authoritySwitchAllowed: current.authoritySwitchAllowed,
      nativeWritesAllowed: current.nativeWritesAllowed,
      records: records ?? current.records,
      storedOrder: storedOrder ?? current.storedOrder,
      ownerOrder: ownerOrder ?? current.ownerOrder, selectionPurposes: current.selectionPurposes,
      selections: selections ?? current.selections, history: history ?? current.history,
      generationHighWater: resolvedHighWater)
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
