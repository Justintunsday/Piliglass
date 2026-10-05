import Foundation

private enum FixtureError: Error { case failed(String), injected }

private actor FaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable { case recordWrite, recordRead, pointerWriteBefore, pointerWriteAfter, pointerReadAfter }
  private var values: [String: Data] = [:]
  private var fault: Fault?
  private var published = false
  private var pause = false
  private var suspended: CheckedContinuation<Void, Never>?
  private let pointer = "ordered-cookie-shadow-manifest-v2"

  func arm(_ next: Fault) { fault = next; published = false }
  func pauseWrite() { pause = true }
  func isPaused() -> Bool { suspended != nil }
  func resume() { suspended?.resume(); suspended = nil }
  func recordCount() -> Int { values.keys.filter { $0 != pointer }.count }
  func corruptRecord() {
    if let key = values.keys.first(where: { $0 != pointer }) { values[key] = Data("corrupt".utf8) }
  }

  func read(_ key: String) throws -> Data? {
    if key != pointer, fault == .recordRead { fault = nil; throw FixtureError.injected }
    if key == pointer, published, fault == .pointerReadAfter { fault = nil; throw FixtureError.injected }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    if pause {
      pause = false
      await withCheckedContinuation { suspended = $0 }
    }
    if key != pointer, fault == .recordWrite { fault = nil; throw FixtureError.injected }
    if key == pointer, fault == .pointerWriteBefore { fault = nil; throw FixtureError.injected }
    values[key] = data
    if key == pointer {
      published = true
      if fault == .pointerWriteAfter { fault = nil; throw FixtureError.injected }
    }
  }
  func remove(_ key: String) { values.removeValue(forKey: key) }
}

@main private struct OrderedCookieStagingChecks {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw FixtureError.failed("exporter golden required") }
    let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]],
          let jar = cases.first(where: { $0["id"] as? String == "live-production-response-with-full-attrs" })?["jar"] else {
      throw FixtureError.failed("actual Dart full-attribute jar missing")
    }
    let data = try JSONSerialization.data(withJSONObject: jar, options: .sortedKeys)
    let codec = PiliOrderedCookieArchiveCodec()
    let expected = try codec.decode(data)
    guard let differentJar = cases.first(where: { $0["id"] as? String == "map-key-distinct-from-cookie-name" })?["jar"] else {
      throw FixtureError.failed("distinct acknowledgment fixture missing")
    }
    let differentData = try JSONSerialization.data(withJSONObject: differentJar, options: .sortedKeys)
    let differentExpected = try codec.decode(differentData)
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw FixtureError.failed(label) }
      checks += 1
    }

    // The vault really uses Security.framework. A new vault actor and new
    // staging actor must restore the complete actual Dart jar from Keychain.
    let namespace = UUID()
    let keychain = PiliAccountKeychainSecretStore(stagingNamespace: namespace)
    let persistent = PiliOrderedCookieStagingStore(secrets: keychain)
    do {
      let first = try await persistent.importShadow(data)
      let second = try await persistent.importShadow(data)
      try check(first.transactionID != second.transactionID, "fresh immutable transaction")
      let restarted = PiliOrderedCookieStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
      try check(try await restarted.loadShadow() == expected, "actual Keychain actor restart")
      try check(await restarted.nativeWritesAllowed == false, "shadow never grants account writes")
      try check(try await keychain.read("ordered-cookie-shadow-v2.\(first.transactionID.uuidString.lowercased())") == nil,
                "previous record cleaned after pointer verification")
      for id in ["map-key-distinct-from-cookie-name", "exact-utf16-keys-in-all-three-map-levels"] {
        guard let alternate = cases.first(where: { $0["id"] as? String == id })?["jar"] else {
          throw FixtureError.failed("actual alternate jar missing")
        }
        let alternateData = try JSONSerialization.data(withJSONObject: alternate, options: .sortedKeys)
        let alternateExpected = try codec.decode(alternateData)
        try await restarted.importShadow(alternateData)
        let fresh = PiliOrderedCookieStagingStore(
          secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
        try check(try await fresh.loadShadow() == alternateExpected, "alternate jar Keychain restart")
      }
      try await restarted.discardShadow()
      try check(try await persistent.loadShadow() == nil, "actual Keychain pointer discarded")
    } catch {
      try? await persistent.discardShadow()
      throw error
    }

    for fault in [FaultVault.Fault.recordWrite, .recordRead, .pointerWriteBefore] {
      let vault = FaultVault()
      let store = PiliOrderedCookieStagingStore(secrets: vault)
      try await store.importShadow(data)
      await vault.arm(fault)
      do { try await store.importShadow(data); throw FixtureError.failed("fault not raised") }
      catch FixtureError.injected { checks += 1 }
      try check(try await store.loadShadow() == expected, "unpublished failure preserves previous pointer")
      try check(await vault.recordCount() == 1, "unpublished candidate removed")
      try await store.discardShadow()
      try check(await vault.recordCount() == 0, "discard removes published record")
    }

    let acknowledgmentVault = FaultVault()
    let acknowledgmentStore = PiliOrderedCookieStagingStore(secrets: acknowledgmentVault)
    let oldReceipt = try await acknowledgmentStore.importShadow(data)
    await acknowledgmentVault.arm(.pointerWriteAfter)
    let recovered = try await acknowledgmentStore.importShadow(differentData)
    try check(recovered.recoveredWriteAcknowledgment, "write-then-error resolved by actual pointer reread")
    try check(recovered.transactionID != oldReceipt.transactionID, "recovered acknowledgment names new pointer")
    try check(try await acknowledgmentStore.loadShadow() == differentExpected, "published record never removed on write error")
    try check(await acknowledgmentVault.recordCount() == 1, "verified publication cleans previous record")

    let unknownVault = FaultVault()
    let unknownStore = PiliOrderedCookieStagingStore(secrets: unknownVault)
    try await unknownStore.importShadow(data)
    await unknownVault.arm(.pointerReadAfter)
    do { try await unknownStore.importShadow(differentData); throw FixtureError.failed("unknown ack not raised") }
    catch PiliOrderedCookieStagingError.publicationUnknown { checks += 1 }
    try check(await unknownVault.recordCount() == 2, "unknown publication preserves both records")
    let recoveredStore = PiliOrderedCookieStagingStore(secrets: unknownVault)
    try check(differentExpected != expected, "acknowledgment fixtures must carry different jars")
    try check(try await recoveredStore.loadShadow() == differentExpected, "restart verifies new durable pointer after unknown ack")

    let invalidVault = FaultVault()
    let invalidStore = PiliOrderedCookieStagingStore(secrets: invalidVault)
    do { try await invalidStore.importShadow(Data("{}".utf8)); throw FixtureError.failed("bad input accepted") }
    catch is PiliOrderedCookieArchiveError { checks += 1 }
    try check(await invalidVault.recordCount() == 0, "invalid input has zero writes")
    try await invalidStore.importShadow(data)
    await invalidVault.corruptRecord()
    do { _ = try await invalidStore.loadShadow(); throw FixtureError.failed("corruption accepted") }
    catch PiliOrderedCookieStagingError.verificationFailed { checks += 1 }

    let fencedVault = FaultVault()
    let fencedStore = PiliOrderedCookieStagingStore(secrets: fencedVault)
    await fencedVault.pauseWrite()
    let pending = Task { try await fencedStore.importShadow(data) }
    for _ in 0..<1000 {
      if await fencedVault.isPaused() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let paused = await fencedVault.isPaused()
    if !paused { pending.cancel(); throw FixtureError.failed("fault vault did not suspend") }
    do { _ = try await fencedStore.loadShadow(); throw FixtureError.failed("reentrant read admitted") }
    catch PiliOrderedCookieStagingError.operationInProgress { checks += 1 }
    do { try await fencedStore.discardShadow(); throw FixtureError.failed("reentrant discard admitted") }
    catch PiliOrderedCookieStagingError.operationInProgress { checks += 1 }
    await fencedVault.resume()
    _ = try await pending.value
    try check(try await fencedStore.loadShadow() == expected, "suspended import completes once")

    await fencedVault.pauseWrite()
    let cancelled = Task { try await fencedStore.importShadow(differentData) }
    for _ in 0..<1000 {
      if await fencedVault.isPaused() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    if !(await fencedVault.isPaused()) { cancelled.cancel(); throw FixtureError.failed("cancel fixture did not suspend") }
    cancelled.cancel()
    await fencedVault.resume()
    do { _ = try await cancelled.value; throw FixtureError.failed("cancelled import published") }
    catch is CancellationError { checks += 1 }
    try check(try await fencedStore.loadShadow() == expected, "cancellation before publication keeps previous jar")
    try check(await fencedVault.recordCount() == 1, "cancelled candidate removed")
    print("\(checks) native ordered Cookie staging checks passed")
  }
}
