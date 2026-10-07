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

/// Durable single-account Cookie transaction over the capture-local shadow.
/// It mutates one exact record's ordered jar through the production reducer,
/// revalidates the whole envelope with the shared cumulative ledger and only
/// then publishes a new immutable candidate through the vault pointer.
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
    try await mutate(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { jar in
      try self.reducer.save(jar, fields: save.fields, representation: save.representation,
                            location: save.location, nowMicroseconds: save.nowMicroseconds)
    }
  }

  func applyCookieDelete(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                         host: String, withDomainSharedCookie: Bool) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await mutate(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { jar in
      try self.reducer.delete(jar, host: host, withDomainSharedCookie: withDomainSharedCookie)
    }
  }

  func applyCookieDeleteAll(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await mutate(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration) { jar in
      try self.reducer.deleteAll(jar)
    }
  }

  private func mutate(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                      _ transform: (PiliOrderedCookieArchive) throws -> PiliOrderedCookieArchive)
    async throws -> PiliAccountShadowTransactionReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let current = try await vault.loadShadow() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
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
    let mutated = try transform(record.jar)
    var records = current.records
    records[index] = PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation,
      storageKeyUnits: record.storageKeyUnits, mid: record.mid, isLogin: record.isLogin,
      accessKeyUnits: record.accessKeyUnits, refreshTokenUnits: record.refreshTokenUnits,
      persistedPurposes: record.persistedPurposes, activated: record.activated, jar: mutated)
    let candidate = PiliAccountLiveMemoryShadow(
      schemaVersion: current.schemaVersion, scope: current.scope, identityScope: current.identityScope,
      revision: current.revision, durableIdentityConfigured: current.durableIdentityConfigured,
      durabilityVerified: current.durabilityVerified,
      authoritySwitchAllowed: current.authoritySwitchAllowed,
      nativeWritesAllowed: current.nativeWritesAllowed, records: records,
      storedOrder: current.storedOrder, ownerOrder: current.ownerOrder,
      selectionPurposes: current.selectionPurposes, selections: current.selections,
      history: current.history)
    // The complete candidate must still fit the shared cumulative ledger.
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await vault.importShadow(codec.encode(candidate))
    return .init(transactionID: publication.transactionID, record: record.record,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
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
