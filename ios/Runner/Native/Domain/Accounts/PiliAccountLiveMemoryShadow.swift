import Foundation

/// Complete capture-local account shadow. Consumes data copied synchronously
/// from the live Dart registry; it supplies no request, storage or authority
/// permission. Every capability flag is fixed false by the same contract.
enum PiliAccountLiveMemoryShadowError: Error, Sendable, Equatable {
  case malformedJSON, duplicateKey, invalidEnvelope, unsupportedSchema, resourceLimit
}

struct PiliAccountLiveMemoryOrderEntry: Sendable, Equatable, Encodable {
  let keyUnits: PiliCookieUTF16
  let record: Int
}

struct PiliAccountLiveMemoryRecord: Sendable, Equatable, Encodable {
  let record: Int
  let generation: Int64
  let storageKeyUnits: PiliCookieUTF16?
  let mid: Int64
  let isLogin: Bool
  let accessKeyUnits: PiliCookieUTF16?
  let refreshTokenUnits: PiliCookieUTF16?
  // Preserve actual Dart Set iteration, not Swift Set iteration.
  let persistedPurposes: [PiliAccountPurpose]
  let activated: Bool
  let jar: PiliOrderedCookieArchive

  private enum CodingKeys: String, CodingKey {
    case record, generation, storageKeyUnits, mid, isLogin
    case accessKeyUnits, refreshTokenUnits, persistedPurposes, activated, jar
  }

  func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(record, forKey: .record)
    try fields.encode(generation, forKey: .generation)
    try fields.encode(mid, forKey: .mid)
    try fields.encode(isLogin, forKey: .isLogin)
    try fields.encode(persistedPurposes, forKey: .persistedPurposes)
    try fields.encode(activated, forKey: .activated)
    try fields.encode(jar, forKey: .jar)
    if let storageKeyUnits { try fields.encode(storageKeyUnits, forKey: .storageKeyUnits) }
    else { try fields.encodeNil(forKey: .storageKeyUnits) }
    if let accessKeyUnits { try fields.encode(accessKeyUnits, forKey: .accessKeyUnits) }
    else { try fields.encodeNil(forKey: .accessKeyUnits) }
    if let refreshTokenUnits { try fields.encode(refreshTokenUnits, forKey: .refreshTokenUnits) }
    else { try fields.encodeNil(forKey: .refreshTokenUnits) }
  }
}

struct PiliAccountLiveMemoryShadow: Sendable, Equatable, Encodable {
  let schemaVersion: Int
  let scope: String
  let identityScope: String
  let revision: Int64
  let durableIdentityConfigured: Bool
  let durabilityVerified: Bool
  let authoritySwitchAllowed: Bool
  let nativeWritesAllowed: Bool
  let records: [PiliAccountLiveMemoryRecord]
  let storedOrder: [PiliAccountLiveMemoryOrderEntry]
  let ownerOrder: [PiliAccountLiveMemoryOrderEntry]
  let selectionPurposes: [PiliAccountPurpose]
  let selections: [Int]
  let history: Int

  func validated(limits: PiliOrderedCookieArchiveLimits = .standard) throws -> Self {
    do { return try validateContents(limits: limits) }
    catch let error as PiliOrderedCookieArchiveError {
      switch error {
      case .malformedJSON: throw PiliAccountLiveMemoryShadowError.malformedJSON
      case .duplicateKey: throw PiliAccountLiveMemoryShadowError.duplicateKey
      case .resourceLimit: throw PiliAccountLiveMemoryShadowError.resourceLimit
      case .invalidArchive, .unsupportedSchema: throw PiliAccountLiveMemoryShadowError.invalidEnvelope
      }
    }
  }

  private func validateContents(limits: PiliOrderedCookieArchiveLimits) throws -> Self {
    let limits = try limits.validated()
    guard schemaVersion == 2 else { throw PiliAccountLiveMemoryShadowError.unsupportedSchema }
    guard !records.isEmpty else { throw PiliAccountLiveMemoryShadowError.invalidEnvelope }
    guard records.count <= 256 else { throw PiliAccountLiveMemoryShadowError.resourceLimit }
    guard scope == "coherentLiveMemoryShadow", identityScope == "captureLocal",
          revision >= 0, !durableIdentityConfigured, !durabilityVerified,
          !authoritySwitchAllowed, !nativeWritesAllowed,
          selectionPurposes == [.main, .heartbeat, .recommend, .video], selections.count == 4,
          selections.allSatisfy({ records.indices.contains($0) }), records.indices.contains(history),
          storedOrder.count == records.count - 1, ownerOrder.count == storedOrder.count else {
      throw PiliAccountLiveMemoryShadowError.invalidEnvelope
    }

    var budget = try PiliOrderedCookieArchiveBudget(limits: limits)
    // Match production capture's conservative metadata reservation once.
    try budget.reserveUnits(2048 + 512 * records.count)
    var generations = Set<Int64>()
    var keys = Set<PiliCookieUTF16>()
    for (index, account) in records.enumerated() {
      guard account.record == index, account.generation > 0,
            generations.insert(account.generation).inserted,
            Set(account.persistedPurposes).count == account.persistedPurposes.count else {
        throw PiliAccountLiveMemoryShadowError.invalidEnvelope
      }
      if index == 0 {
        guard !account.isLogin, account.mid == 0, account.storageKeyUnits == nil,
              account.accessKeyUnits == nil, account.refreshTokenUnits == nil else {
          throw PiliAccountLiveMemoryShadowError.invalidEnvelope
        }
        // AnonymousAccount.type is mutable and can contain actual purposes.
      } else {
        guard account.isLogin, let key = account.storageKeyUnits,
              keys.insert(key).inserted else { throw PiliAccountLiveMemoryShadowError.invalidEnvelope }
        // MID is captured profile data, not unique owner identity or raw key policy.
      }
      try budget.count(account.storageKeyUnits, maximum: limits.maximumBucketKeyUnits)
      try budget.count(account.accessKeyUnits, maximum: limits.maximumValueUnits)
      try budget.count(account.refreshTokenUnits, maximum: limits.maximumValueUnits)
      _ = try account.jar.validated(budget: &budget)
    }
    for (offset, entry) in storedOrder.enumerated() {
      guard entry.record == offset + 1, entry.keyUnits == records[entry.record].storageKeyUnits else {
        throw PiliAccountLiveMemoryShadowError.invalidEnvelope
      }
      try budget.count(entry.keyUnits, maximum: limits.maximumBucketKeyUnits)
    }
    var owners = Set<Int>()
    for entry in ownerOrder {
      guard entry.record > 0, records.indices.contains(entry.record),
            owners.insert(entry.record).inserted,
            entry.keyUnits == records[entry.record].storageKeyUnits else {
        throw PiliAccountLiveMemoryShadowError.invalidEnvelope
      }
      try budget.count(entry.keyUnits, maximum: limits.maximumBucketKeyUnits)
    }
    let heartbeat = selections[1]
    guard history == (records[heartbeat].isLogin ? heartbeat : selections[0]) else {
      throw PiliAccountLiveMemoryShadowError.invalidEnvelope
    }
    // Full wire bytes / strict grammar / JSON nodes / depth belong to codec.
    // No owner UUID, authorityEpoch, durable record or restart authorization.
    return self
  }
}
