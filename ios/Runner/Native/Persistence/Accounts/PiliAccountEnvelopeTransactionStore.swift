import Foundation

enum PiliAccountShadowTransactionError: Error, Sendable, Equatable {
  case operationInProgress, shadowUnavailable, unknownRecordKey, staleGeneration
}

struct PiliAccountShadowCookieSave: Sendable, Equatable {
  let fields: [String]
  let representation: PiliNativeCookieFieldRepresentation
  let location: PiliOrderedCookieResponseLocation
  let nowMicroseconds: Int64
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
    let slot: Int
    switch purpose {
    case .main: slot = 0
    case .heartbeat: slot = 1
    case .recommend: slot = 2
    case .video: slot = 3
    }
    return try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { current, index in
      var selections = current.selections
      selections[slot] = current.records[index].record
      let heartbeat = selections[1]
      let history = current.records[heartbeat].isLogin ? heartbeat : selections[0]
      return self.replace(current, selections: selections, history: history)
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
        activated: record.activated, jar: record.jar)
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
        activated: activated, jar: record.jar)
      return self.replace(current, records: records)
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

  private func replaceJar(_ current: PiliAccountLiveMemoryShadow, index: Int,
                          jar: PiliOrderedCookieArchive) -> PiliAccountLiveMemoryShadow {
    let record = current.records[index]
    var records = current.records
    records[index] = PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: jar)
    return replace(current, records: records)
  }

  private func replace(_ current: PiliAccountLiveMemoryShadow,
                       records: [PiliAccountLiveMemoryRecord]? = nil,
                       selections: [Int]? = nil,
                       history: Int? = nil) -> PiliAccountLiveMemoryShadow {
    PiliAccountLiveMemoryShadow(
      schemaVersion: current.schemaVersion, scope: current.scope, identityScope: current.identityScope,
      revision: current.revision, durableIdentityConfigured: current.durableIdentityConfigured,
      durabilityVerified: current.durabilityVerified,
      authoritySwitchAllowed: current.authoritySwitchAllowed,
      nativeWritesAllowed: current.nativeWritesAllowed,
      records: records ?? current.records, storedOrder: current.storedOrder,
      ownerOrder: current.ownerOrder, selectionPurposes: current.selectionPurposes,
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
