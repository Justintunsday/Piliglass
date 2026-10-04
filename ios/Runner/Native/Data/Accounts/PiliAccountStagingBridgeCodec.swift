import Foundation

struct PiliAccountStagingEntry: Sendable, Equatable, Codable {
  let credentials: PiliAccountCredentialRecord
  let cookies: PiliAccountCookieArchive
}

struct PiliAccountStagingExport: Sendable, Equatable {
  let snapshot: PiliAccountSelectionSnapshot
  let entries: [PiliAccountStagingEntry]
}

enum PiliAccountStagingBridgeCodec {
  static func decode(_ value: PiliBridgeValue) throws -> PiliAccountStagingExport {
    let codec = PiliAccountSnapshotBridgeCodec.self
    let fields = try codec.fields(value, keys: ["schemaVersion", "authority", "nativeWritesAllowed", "snapshot", "entries"])
    guard fields["schemaVersion"] == .integer(1), fields["authority"] == .string("dartHive"),
          fields["nativeWritesAllowed"] == .bool(false), let rawSnapshot = fields["snapshot"],
          case .array(let rawEntries) = fields["entries"], rawEntries.count <= 256 else { throw invalid }
    let snapshot = try codec.decode(rawSnapshot)
    let entries = try rawEntries.map { value -> PiliAccountStagingEntry in
      let entry = try codec.fields(value, keys: ["identity", "accessKey", "refreshToken", "ignoreExpires",
        "legacyHiveAttributesIncomplete", "cookies"])
      let identity = try codec.identity(entry["identity"])
      guard case .array(let rawCookies) = entry["cookies"], rawCookies.count <= 4096 else { throw invalid }
      let cookies = try rawCookies.map { value -> PiliAccountCookieRecord in
        let c = try codec.fields(value, keys: ["name", "value", "domain", "path", "hostOnly", "cookieDomain",
          "cookiePath", "secure", "httpOnly", "sameSite", "expiresMicroseconds", "maxAgeSeconds", "createdSeconds", "sequence"])
        guard let sequence = Int(exactly: try codec.integer(c["sequence"])) else { throw invalid }
        return try PiliAccountCookieRecord(name: codec.string(c["name"]), value: codec.string(c["value"]),
          domain: codec.string(c["domain"]), path: codec.string(c["path"]), hostOnly: codec.boolean(c["hostOnly"]),
          cookieDomain: optionalString(c["cookieDomain"]), cookiePath: optionalString(c["cookiePath"]),
          secure: codec.boolean(c["secure"]), httpOnly: codec.boolean(c["httpOnly"]),
          sameSite: optionalString(c["sameSite"]), expiresMicroseconds: optionalInteger(c["expiresMicroseconds"]),
          maxAgeSeconds: optionalInteger(c["maxAgeSeconds"]),
          createdSeconds: codec.integer(c["createdSeconds"]), sequence: sequence)
      }
      let archive = try PiliAccountCookieArchive(schemaVersion: 1, identity: identity,
        ignoreExpires: codec.boolean(entry["ignoreExpires"]),
        legacyHiveAttributesIncomplete: codec.boolean(entry["legacyHiveAttributesIncomplete"]), cookies: cookies).validated()
      return try PiliAccountStagingEntry(credentials: PiliAccountCredentialRecord(identity: identity,
        accessKey: optionalString(entry["accessKey"]), refreshToken: optionalString(entry["refreshToken"])), cookies: archive)
    }
    guard Set(entries.map { $0.credentials.identity }) == Set(snapshot.accounts.map(\.identity)),
          entries.count == snapshot.accounts.count else { throw invalid }
    for entry in entries {
      guard let account = snapshot.accounts.first(where: { $0.identity == entry.credentials.identity }),
            account.hasAccessKey == !(entry.credentials.accessKey ?? "").isEmpty,
            account.hasRefreshToken == !(entry.credentials.refreshToken ?? "").isEmpty else { throw invalid }
    }
    return PiliAccountStagingExport(snapshot: snapshot, entries: entries)
  }

  private static func optionalString(_ value: PiliBridgeValue?) throws -> String? {
    if value == .null { return nil }
    let result = try PiliAccountSnapshotBridgeCodec.string(value)
    guard result.utf8.count <= 65536 else { throw invalid }; return result
  }
  private static func optionalInteger(_ value: PiliBridgeValue?) throws -> Int64? {
    if value == .null { return nil }; return try PiliAccountSnapshotBridgeCodec.integer(value)
  }
  private static var invalid: PiliAccountRepositoryError { .invalidSnapshot }
}
