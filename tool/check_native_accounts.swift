import Foundation

private enum FixtureFailure: Error { case failed(String) }

private actor MemorySecrets: PiliAccountSecretStore {
  private var values: [String: Data] = [:]
  private var failManifest = false
  func read(_ key: String) -> Data? { values[key] }
  func write(_ data: Data, key: String) throws {
    if failManifest && key == "staging-manifest-v1" {
      failManifest = false
      throw PiliAccountStorageError.invalidArchive
    }
    values[key] = data
  }
  func remove(_ key: String) { values.removeValue(forKey: key) }
  func failNextManifest() { failManifest = true }
  func count() -> Int { values.count }
}

@MainActor
private final class FixtureInvoker: PiliBridgeMethodInvoking {
  let value: PiliBridgeValue
  var calls = 0
  init(value: PiliBridgeValue) { self.value = value }
  func invoke(_ method: String, arguments: [String: PiliBridgeValue]?) async throws -> PiliBridgeValue {
    guard method == "loadNativeAccountSelection", arguments == nil else { throw FixtureFailure.failed("repository method") }
    calls += 1
    return value
  }
}

@main
@MainActor
private struct NativeAccountsFixture {
  static var checks = 0
  static func check(_ value: Bool, _ message: String) throws {
    guard value else { throw FixtureFailure.failed(message) }
    checks += 1
  }

  static func main() async throws {
    guard CommandLine.arguments.count == 3 else { throw FixtureFailure.failed("two actual Dart exports required") }
    var exports: [PiliAccountStagingExport] = []
    for path in CommandLine.arguments.dropFirst() {
      let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
      let raw = try PiliBridgeValue(codecValue: object)
      let exported = try PiliAccountStagingBridgeCodec.decode(raw)
      exports.append(exported)
      try check(!exported.snapshot.nativeWritesAllowed, "Dart remains authority")
      try check(exported.entries.count == exported.snapshot.accounts.count, "all owners copied")
      try check(exported.entries.allSatisfy { $0.cookies.legacyHiveAttributesIncomplete }, "honest Hive provenance")
      let snapshot = exported.snapshot
      let heartbeat = snapshot.account(for: .heartbeat)!
      try check(snapshot.history == (heartbeat.isLogin ? heartbeat.identity : snapshot.account(for: .main)!.identity), "history owner")
      guard case .dictionary(let fields) = raw, let snapshotValue = fields["snapshot"] else { throw FixtureFailure.failed("snapshot shape") }
      let invoker = FixtureInvoker(value: snapshotValue)
      let repository = PiliAccountFlutterRepository(invoker: invoker)
      let received = try await repository.selectionSnapshot()
      try check(received == snapshot && invoker.calls == 1, "production repository consumes actual bridge snapshot")
      try strictCases(snapshotValue)
      try await sessionCases(snapshot)
      try await stagingCases(exported)
    }
    let live = exports[0].entries.flatMap { $0.cookies.cookies }
    try check(live.filter { $0.name == "duplicate" }.count == 2, "duplicate name/path retained")
    try check(live.contains { $0.name == "host" && $0.hostOnly && $0.cookieDomain == nil && $0.expiresMicroseconds != nil }, "host-only expiry retained")
    try check(live.contains { $0.name == "duplicate" && $0.secure && $0.httpOnly && $0.maxAgeSeconds == 500 }, "secure/httpOnly/maxAge retained")
    try check(live.contains { $0.name == "duplicate" && $0.sameSite == "Lax" }, "SameSite retained")
    let restored = exports[1].entries.flatMap { $0.cookies.cookies }
    try check(!restored.contains { $0.name == "nested_lost" || $0.name == "host_lost" }, "actual Hive lost non-root cookies")
    try check(restored.contains { $0.name == "root_metadata" && !$0.secure && !$0.httpOnly && $0.maxAgeSeconds == nil }, "actual Hive lost attributes")
    try await keychainCase()
    print("\(checks) native account checks passed")
  }

  static func strictCases(_ raw: PiliBridgeValue) throws {
    guard case .dictionary(let original) = raw else { throw FixtureFailure.failed("dictionary") }
    let changes: [(String, PiliBridgeValue)] = [("schemaVersion", .integer(2)), ("revision", .bool(true)),
      ("revision", .integer(-1)), ("nativeWritesAllowed", .bool(true)), ("authorityEpoch", .string("bad")),
      ("authority", .string("native")), ("selections", .array([])), ("history", .null), ("unknown", .null)]
    for (key, value) in changes {
      var bad = original; bad[key] = value
      do {
        _ = try PiliAccountSnapshotBridgeCodec.decode(.dictionary(bad))
        throw FixtureFailure.failed("accepted invalid snapshot \(key)")
      } catch is PiliAccountRepositoryError { checks += 1 }
    }
  }

  static func withRevision(_ snapshot: PiliAccountSelectionSnapshot, _ revision: Int64, epoch: String? = nil) -> PiliAccountSelectionSnapshot {
    PiliAccountSelectionSnapshot(authorityEpoch: epoch ?? snapshot.authorityEpoch, revision: revision,
      accounts: snapshot.accounts, selections: snapshot.selections, history: snapshot.history)
  }

  static func sessionCases(_ snapshot: PiliAccountSelectionSnapshot) async throws {
    let session = PiliAccountSession(authorityEpoch: snapshot.authorityEpoch)
    try await session.install(snapshot)
    try await session.install(snapshot)
    try check(await session.current() == snapshot, "same revision identical snapshot idempotent")
    do {
      try await session.install(withRevision(snapshot, snapshot.revision - 1))
      throw FixtureFailure.failed("accepted late revision")
    } catch PiliAccountRepositoryError.staleSnapshot { checks += 1 }
    let epoch = UUID().uuidString.lowercased()
    let foreign = withRevision(snapshot, snapshot.revision + 1, epoch: epoch)
    do {
      try await session.install(foreign)
      throw FixtureFailure.failed("callback changed epoch")
    } catch PiliAccountRepositoryError.epochMismatch { checks += 1 }
    try await session.resetAuthority(to: epoch)
    try check(await session.current() == nil, "explicit authority reset clears old data")
    try await session.install(foreign)
    try check(await session.current() == foreign, "explicit new epoch accepted")
  }

  static func stagingCases(_ input: PiliAccountStagingExport) async throws {
    let secrets = MemorySecrets()
    let store = PiliAccountStagingStore(secrets: secrets)
    try await store.importShadow(input)
    try check(await store.nativeWritesAllowed == false, "staging cannot become authority")
    let restarted = PiliAccountStagingStore(secrets: secrets)
    try check(try await restarted.loadShadow() == input, "native restart preserves exact full export")
    try await restarted.importShadow(input)
    try check(await secrets.count() == input.entries.count * 2 + 1, "repeat import cleans old transaction")
    await secrets.failNextManifest()
    do {
      try await restarted.importShadow(input)
      throw FixtureFailure.failed("accepted failed commit")
    } catch PiliAccountStorageError.invalidArchive { checks += 1 }
    try check(try await restarted.loadShadow() == input, "failed import preserves old committed transaction")
    try check(await secrets.count() == input.entries.count * 2 + 1, "failed import cleans new secret records")
    let older = PiliAccountStagingExport(snapshot: withRevision(input.snapshot, input.snapshot.revision - 1), entries: input.entries)
    do {
      try await restarted.importShadow(older)
      throw FixtureFailure.failed("accepted stale shadow")
    } catch PiliAccountRepositoryError.staleSnapshot { checks += 1 }
    try await restarted.discardShadow()
    let discarded = try await restarted.loadShadow()
    let retained = await secrets.count()
    try check(discarded == nil && retained == 0, "discard shadow leaves no native data")
    let cancelled = Task { try await restarted.importShadow(input) }
    cancelled.cancel()
    do {
      try await cancelled.value
      throw FixtureFailure.failed("accepted cancelled staging import")
    } catch is CancellationError { checks += 1 }
    try check(await secrets.count() == 0, "cancelled import keeps Dart authority and no shadow records")
  }

  static func keychainCase() async throws {
    let store = PiliAccountKeychainSecretStore(stagingNamespace: UUID())
    let payload = Data("synthetic-keychain-roundtrip".utf8)
    try await store.write(payload, key: "fixture")
    try check(try await store.read("fixture") == payload, "actual Security Keychain read/write")
    try await store.write(Data("replacement".utf8), key: "fixture")
    try check(try await store.read("fixture") == Data("replacement".utf8), "actual Security Keychain update")
    try await store.remove("fixture")
    try check(try await store.read("fixture") == nil, "actual Security Keychain cleanup")
  }
}
