import Foundation

enum PiliAccountSnapshotBridgeCodec {
  static func decode(_ value: PiliBridgeValue) throws -> PiliAccountSelectionSnapshot {
    let f = try fields(value, keys: ["schemaVersion", "authority", "authorityEpoch", "revision",
      "nativeWritesAllowed", "accounts", "selections", "history"])
    guard f["schemaVersion"] == .integer(1), f["authority"] == .string("dartHive"),
          f["nativeWritesAllowed"] == .bool(false),
          case .array(let rawAccounts) = f["accounts"], rawAccounts.count <= 256,
          case .array(let rawSelections) = f["selections"], rawSelections.count == 4 else { throw invalid }
    let accounts = try rawAccounts.map { value -> PiliAccountDescriptor in
      let a = try fields(value, keys: ["identity", "mid", "isLogin", "activated", "hasAccessKey",
        "hasRefreshToken", "persistedPurposes"])
      guard case .array(let rawPurposes) = a["persistedPurposes"] else { throw invalid }
      let purposes = try rawPurposes.map(purpose)
      guard Set(purposes).count == purposes.count else { throw invalid }
      return PiliAccountDescriptor(identity: try identity(a["identity"]), mid: try integer(a["mid"]),
        isLogin: try boolean(a["isLogin"]), activated: try boolean(a["activated"]),
        hasAccessKey: try boolean(a["hasAccessKey"]), hasRefreshToken: try boolean(a["hasRefreshToken"]),
        persistedPurposes: Set(purposes))
    }
    let selections = try rawSelections.map { value -> PiliAccountSelection in
      let s = try fields(value, keys: ["purpose", "identity", "temporary"])
      guard let raw = s["purpose"] else { throw invalid }
      return PiliAccountSelection(purpose: try purpose(raw), identity: try identity(s["identity"]),
        temporary: try boolean(s["temporary"]))
    }
    return try PiliAccountSelectionSnapshot(authorityEpoch: string(f["authorityEpoch"]),
      revision: integer(f["revision"]), accounts: accounts, selections: selections,
      history: identity(f["history"])).validated()
  }

  static func identity(_ value: PiliBridgeValue?) throws -> PiliAccountIdentity {
    guard let value else { throw invalid }
    let f = try fields(value, keys: ["ownerToken", "generation"])
    let token = try string(f["ownerToken"])
    let generation = try integer(f["generation"])
    guard token.utf8.count == 36, UUID(uuidString: token) != nil, generation > 0 else { throw invalid }
    return PiliAccountIdentity(ownerToken: token, generation: generation)
  }

  static func fields(_ value: PiliBridgeValue, keys: Set<String>) throws -> [String: PiliBridgeValue] {
    guard case .dictionary(let fields) = value, Set(fields.keys) == keys else { throw invalid }
    return fields
  }
  static func string(_ value: PiliBridgeValue?) throws -> String {
    guard case .string(let value) = value else { throw invalid }; return value
  }
  static func integer(_ value: PiliBridgeValue?) throws -> Int64 {
    guard case .integer(let value) = value else { throw invalid }; return value
  }
  static func boolean(_ value: PiliBridgeValue?) throws -> Bool {
    guard case .bool(let value) = value else { throw invalid }; return value
  }
  private static func purpose(_ value: PiliBridgeValue) throws -> PiliAccountPurpose {
    guard let purpose = PiliAccountPurpose(rawValue: try string(value)) else { throw invalid }; return purpose
  }
  private static var invalid: PiliAccountRepositoryError { .invalidSnapshot }
}
