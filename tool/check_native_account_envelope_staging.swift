import Foundation

private enum StagingFixtureError: Error { case failed(String), injected }

private actor EnvelopeFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable { case recordWrite, recordRead, pointerWriteBefore, pointerWriteAfter, pointerReadAfter }
  private var values: [String: Data] = [:]
  private var fault: Fault?
  private var published = false
  private var pause = false
  private var suspended: CheckedContinuation<Void, Never>?
  private let pointer = "account-envelope-shadow-manifest-v2"

  func arm(_ next: Fault) { fault = next; published = false }
  func pauseWrite() { pause = true }
  func isPaused() -> Bool { suspended != nil }
  func resume() { suspended?.resume(); suspended = nil }
  func recordCount() -> Int { values.keys.filter { $0 != pointer }.count }
  func corruptRecord() {
    if let key = values.keys.first(where: { $0 != pointer }) { values[key] = Data("corrupt".utf8) }
  }

  func read(_ key: String) throws -> Data? {
    if key != pointer, fault == .recordRead { fault = nil; throw StagingFixtureError.injected }
    if key == pointer, published, fault == .pointerReadAfter { fault = nil; throw StagingFixtureError.injected }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    if pause {
      pause = false
      await withCheckedContinuation { suspended = $0 }
    }
    if key != pointer, fault == .recordWrite { fault = nil; throw StagingFixtureError.injected }
    if key == pointer, fault == .pointerWriteBefore { fault = nil; throw StagingFixtureError.injected }
    values[key] = data
    if key == pointer {
      published = true
      if fault == .pointerWriteAfter { fault = nil; throw StagingFixtureError.injected }
    }
  }
  func remove(_ key: String) { values.removeValue(forKey: key) }
}

@main private struct AccountEnvelopeStagingChecks {
  static func main() async throws {
    guard CommandLine.arguments.count == 3 else {
      throw StagingFixtureError.failed("fresh live and cold actual Dart envelope goldens required")
    }
    func envelope(_ path: String, id: String) throws -> Data {
      let raw = try Data(contentsOf: URL(fileURLWithPath: path))
      guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let cases = root["cases"] as? [[String: Any]],
            let value = cases.first(where: { $0["id"] as? String == id })?["envelope"] else {
        throw StagingFixtureError.failed("actual Dart envelope missing: \(id)")
      }
      return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    let data = try envelope(CommandLine.arguments[1], id: "stored-10-2-owner-2-10")
    let differentData = try envelope(CommandLine.arguments[2], id: "actual-hive-reopen-before-refresh")
    let codec = PiliAccountLiveMemoryShadowCodec()
    let expected = try codec.decode(data)
    let differentExpected = try codec.decode(differentData)
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw StagingFixtureError.failed(label) }
      checks += 1
    }
    try check(expected != differentExpected, "staging fixtures must differ")
    try check(!expected.nativeWritesAllowed && !differentExpected.nativeWritesAllowed,
              "actual captured envelopes never grant Native writes")

    // The vault really uses Security.framework. A new store actor on a new
    // namespace must restore the complete actual Dart envelope from Keychain.
    let namespace = UUID()
    let keychain = PiliAccountKeychainSecretStore(stagingNamespace: namespace)
    let persistent = PiliAccountEnvelopeStagingStore(secrets: keychain)
    do {
      let first = try await persistent.importShadow(data)
      let second = try await persistent.importShadow(data)
      try check(first.transactionID != second.transactionID, "fresh immutable transaction")
      let restarted = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
      try check(try await restarted.loadShadow() == expected, "actual Keychain actor restart")
      try check(await restarted.nativeWritesAllowed == false, "shadow never grants account writes")
      try check(try await keychain.read(
        "account-envelope-shadow-v2.\(first.transactionID.uuidString.lowercased())") == nil,
        "previous record cleaned after pointer verification")
      try await restarted.importShadow(differentData)
      let fresh = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
      try check(try await fresh.loadShadow() == differentExpected, "alternate envelope Keychain restart")
      try await fresh.discardShadow()
      try check(try await persistent.loadShadow() == nil, "actual Keychain pointer discarded")
    } catch {
      try? await persistent.discardShadow()
      throw error
    }

    for fault in [EnvelopeFaultVault.Fault.recordWrite, .recordRead, .pointerWriteBefore] {
      let vault = EnvelopeFaultVault()
      let store = PiliAccountEnvelopeStagingStore(secrets: vault)
      try await store.importShadow(data)
      await vault.arm(fault)
      do { try await store.importShadow(differentData); throw StagingFixtureError.failed("fault not raised") }
      catch StagingFixtureError.injected { checks += 1 }
      try check(try await store.loadShadow() == expected, "unpublished failure preserves previous pointer")
      try check(await vault.recordCount() == 1, "unpublished candidate removed")
      try await store.discardShadow()
      try check(await vault.recordCount() == 0, "discard removes published record")
    }

    let acknowledgmentVault = EnvelopeFaultVault()
    let acknowledgmentStore = PiliAccountEnvelopeStagingStore(secrets: acknowledgmentVault)
    let oldReceipt = try await acknowledgmentStore.importShadow(data)
    await acknowledgmentVault.arm(.pointerWriteAfter)
    let recovered = try await acknowledgmentStore.importShadow(differentData)
    try check(recovered.recoveredWriteAcknowledgment, "write-then-error resolved by actual pointer reread")
    try check(recovered.transactionID != oldReceipt.transactionID, "recovered acknowledgment names new pointer")
    try check(try await acknowledgmentStore.loadShadow() == differentExpected, "published record never removed on write error")
    try check(await acknowledgmentVault.recordCount() == 1, "verified publication cleans previous record")

    let unknownVault = EnvelopeFaultVault()
    let unknownStore = PiliAccountEnvelopeStagingStore(secrets: unknownVault)
    try await unknownStore.importShadow(data)
    await unknownVault.arm(.pointerReadAfter)
    do { try await unknownStore.importShadow(differentData); throw StagingFixtureError.failed("unknown ack not raised") }
    catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
    try check(await unknownVault.recordCount() == 2, "unknown publication preserves both records")
    let recoveredStore = PiliAccountEnvelopeStagingStore(secrets: unknownVault)
    try check(try await recoveredStore.loadShadow() == differentExpected,
              "restart verifies new durable pointer after unknown ack")

    let invalidVault = EnvelopeFaultVault()
    let invalidStore = PiliAccountEnvelopeStagingStore(secrets: invalidVault)
    do { try await invalidStore.importShadow(Data("{}".utf8)); throw StagingFixtureError.failed("bad input accepted") }
    catch is PiliAccountLiveMemoryShadowError { checks += 1 }
    try check(await invalidVault.recordCount() == 0, "invalid input has zero writes")
    try await invalidStore.importShadow(data)
    await invalidVault.corruptRecord()
    do { _ = try await invalidStore.loadShadow(); throw StagingFixtureError.failed("corruption accepted") }
    catch PiliAccountEnvelopeStagingError.verificationFailed { checks += 1 }

    let fencedVault = EnvelopeFaultVault()
    let fencedStore = PiliAccountEnvelopeStagingStore(secrets: fencedVault)
    await fencedVault.pauseWrite()
    let pending = Task { try await fencedStore.importShadow(data) }
    for _ in 0..<1000 {
      if await fencedVault.isPaused() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    if !(await fencedVault.isPaused()) { pending.cancel(); throw StagingFixtureError.failed("fault vault did not suspend") }
    do { _ = try await fencedStore.loadShadow(); throw StagingFixtureError.failed("reentrant read admitted") }
    catch PiliAccountEnvelopeStagingError.operationInProgress { checks += 1 }
    do { try await fencedStore.discardShadow(); throw StagingFixtureError.failed("reentrant discard admitted") }
    catch PiliAccountEnvelopeStagingError.operationInProgress { checks += 1 }
    await fencedVault.resume()
    _ = try await pending.value
    try check(try await fencedStore.loadShadow() == expected, "suspended import completes once")

    await fencedVault.pauseWrite()
    let cancelled = Task { try await fencedStore.importShadow(differentData) }
    for _ in 0..<1000 {
      if await fencedVault.isPaused() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    if !(await fencedVault.isPaused()) { cancelled.cancel(); throw StagingFixtureError.failed("cancel fixture did not suspend") }
    cancelled.cancel()
    await fencedVault.resume()
    do { _ = try await cancelled.value; throw StagingFixtureError.failed("cancelled import published") }
    catch is CancellationError { checks += 1 }
    try check(try await fencedStore.loadShadow() == expected, "cancellation before publication keeps previous envelope")
    try check(await fencedVault.recordCount() == 1, "cancelled candidate removed")
    print("\(checks) native account envelope staging checks passed")
  }
}
