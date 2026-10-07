import Foundation

private enum TransactionFixtureError: Error { case failed(String), injected }

private actor TransactionFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable { case pointerWriteAfter, pointerReadAfter }
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

  func read(_ key: String) throws -> Data? {
    if key == pointer, published, fault == .pointerReadAfter { fault = nil; throw TransactionFixtureError.injected }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    if pause {
      pause = false
      await withCheckedContinuation { suspended = $0 }
    }
    values[key] = data
    if key == pointer {
      published = true
      if fault == .pointerWriteAfter { fault = nil; throw TransactionFixtureError.injected }
    }
  }
  func remove(_ key: String) { values.removeValue(forKey: key) }
}

@main private struct AccountEnvelopeTransactionChecks {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw TransactionFixtureError.failed("fresh live actual Dart envelope golden required")
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]],
          let value = cases.first(where: { $0["id"] as? String == "stored-10-2-owner-2-10" })?["envelope"] else {
      throw TransactionFixtureError.failed("actual Dart envelope missing")
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let codec = PiliAccountLiveMemoryShadowCodec()
    let base = try codec.decode(data)
    guard base.records.count == 3 else { throw TransactionFixtureError.failed("expected anonymous + two login records") }
    let record = base.records[1]
    guard let key = record.storageKeyUnits, key.units == Array("10".utf16) else {
      throw TransactionFixtureError.failed("expected raw storage key 10")
    }
    let reducer = PiliNativeOrderedCookieReducer()
    let location = PiliOrderedCookieResponseLocation(host: "api.bilibili.com", path: "/x/test")
    let now: Int64 = 1_700_000_000_123_456
    let fields = ["txn-cookie=txn-value; Path=/; Domain=.bilibili.com"]
    let saved = try reducer.save(record.jar, fields: fields, representation: .separated,
                                 location: location, nowMicroseconds: now)
    let deleted = try reducer.delete(saved, host: "bilibili.com", withDomainSharedCookie: true)
    guard deleted.domainBuckets.isEmpty else {
      throw TransactionFixtureError.failed("actual domain deletion fixture missing")
    }
    let cleared = try reducer.deleteAll(deleted)
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw TransactionFixtureError.failed(label) }
      checks += 1
    }

    // The vault really uses Security.framework and the transaction really
    // publishes a new immutable envelope pointer.
    let namespace = UUID()
    let keychain = PiliAccountKeychainSecretStore(stagingNamespace: namespace)
    let vault = PiliAccountEnvelopeStagingStore(secrets: keychain)
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(codec.encode(base))
      let receipt = try await store.applyCookieSave(recordKeyUnits: key,
        expectedGeneration: record.generation,
        .init(fields: fields, representation: .separated, location: location, nowMicroseconds: now))
      try check(receipt.nativeWritesAllowed == false && receipt.authoritySwitchAllowed == false,
                "transaction never grants authority")
      try check(receipt.record == 1, "transaction names the exact record")
      let restartedVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
      let restarted = try await restartedVault.loadShadow()
      try check(restarted?.records[1].jar == saved, "durable save equals production reducer")
      try check(restarted?.records[2].jar == base.records[2].jar, "other record jar unchanged")
      try check(restarted?.storedOrder == base.storedOrder && restarted?.ownerOrder == base.ownerOrder,
                "account order preserved across transaction")
      try check(restarted?.records.count == base.records.count && restarted?.records[0] == base.records[0],
                "transaction preserves the complete record collection")
      try check(restarted?.selections == base.selections && restarted?.history == base.history,
                "transaction preserves effective selections and history")
      try check(restarted?.revision == base.revision && restarted?.records[1].generation == record.generation,
                "capture-local identity is not renumbered")
      let second = PiliAccountEnvelopeTransactionStore(vault: restartedVault)
      _ = try await second.applyTemporarySelection(recordKeyUnits: key,
        expectedGeneration: record.generation, purpose: .heartbeat)
      let afterSelection = try await restartedVault.loadShadow()
      try check(afterSelection?.selections == [0, record.record, 0, 0] &&
        afterSelection?.history == record.record,
        "temporary selection updates only the slot and derives actual history")
      _ = try await second.applyCredentials(recordKeyUnits: key, expectedGeneration: record.generation,
        accessKeyUnits: PiliCookieUTF16(units: Array("synthetic-tx-access".utf16)),
        refreshTokenUnits: nil)
      var afterCredentials = try await restartedVault.loadShadow()
      try check(afterCredentials?.records[1].accessKeyUnits?.units == Array("synthetic-tx-access".utf16) &&
        afterCredentials?.records[1].refreshTokenUnits == nil &&
        afterCredentials?.records[2].accessKeyUnits == base.records[2].accessKeyUnits,
        "durable credentials replacement stays inside one record")
      do {
        _ = try await second.applyCredentials(recordKeyUnits: key, expectedGeneration: record.generation,
          accessKeyUnits: PiliCookieUTF16(units: Array(repeating: 97, count: 65537)),
          refreshTokenUnits: nil)
        throw TransactionFixtureError.failed("oversized credentials accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
      afterCredentials = try await restartedVault.loadShadow()
      try check(afterCredentials?.records[1].accessKeyUnits?.units == Array("synthetic-tx-access".utf16),
                "oversized credentials never publish")
      _ = try await second.applyActivated(recordKeyUnits: key, expectedGeneration: record.generation,
                                          activated: false)
      let afterActivated = try await restartedVault.loadShadow()
      try check(afterActivated?.records[1].activated == false, "durable activated replacement")
      _ = try await second.applyCookieDelete(recordKeyUnits: key,
        expectedGeneration: record.generation, host: "bilibili.com", withDomainSharedCookie: true)
      let afterDelete = try await restartedVault.loadShadow()
      try check(afterDelete?.records[1].jar == deleted, "durable delete equals production reducer")
      _ = try await second.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
      let afterClear = try await restartedVault.loadShadow()
      try check(afterClear?.records[1].jar == cleared, "durable clear equals production reducer")
      try check(afterClear?.records[2].jar == base.records[2].jar, "clear stays inside one record")
      try await restartedVault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }

    // Rejections must leave the previous durable pointer untouched.
    let rejectNamespace = UUID()
    let rejectVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: rejectNamespace))
    let rejectStore = PiliAccountEnvelopeTransactionStore(vault: rejectVault)
    do {
      try await rejectVault.importShadow(codec.encode(base))
      do {
        _ = try await rejectStore.applyCookieDeleteAll(
          recordKeyUnits: PiliCookieUTF16(units: Array("missing".utf16)),
          expectedGeneration: record.generation)
        throw TransactionFixtureError.failed("unknown record key accepted")
      } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
      do {
        _ = try await rejectStore.applyCookieDeleteAll(
          recordKeyUnits: key, expectedGeneration: record.generation + 1)
        throw TransactionFixtureError.failed("stale generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await rejectStore.applyCookieSave(recordKeyUnits: key,
          expectedGeneration: record.generation,
          .init(fields: ["bad\r\nfield"], representation: .separated, location: location,
                nowMicroseconds: now))
        throw TransactionFixtureError.failed("malformed field accepted")
      } catch is PiliNativeCookieError { checks += 1 }
      let unchanged = try await rejectVault.loadShadow()
      try check(unchanged == base, "rejections never publish a new candidate")
      try await rejectVault.discardShadow()
    } catch {
      try? await rejectVault.discardShadow()
      throw error
    }

    // Write-then-error re-reads the pointer; unknown acknowledgment publishes
    // and must never be replayed or silently rolled back.
    let ackVault = TransactionFaultVault()
    let ackStore = PiliAccountEnvelopeTransactionStore(
      vault: PiliAccountEnvelopeStagingStore(secrets: ackVault))
    let ackVaultStore = PiliAccountEnvelopeStagingStore(secrets: ackVault)
    try await ackVaultStore.importShadow(codec.encode(base))
    await ackVault.arm(.pointerWriteAfter)
    let recovered = try await ackStore.applyCookieSave(recordKeyUnits: key,
      expectedGeneration: record.generation,
      .init(fields: fields, representation: .separated, location: location, nowMicroseconds: now))
    try check(recovered.nativeWritesAllowed == false, "recovered publication keeps gates closed")
    let ackReloaded = try await PiliAccountEnvelopeStagingStore(secrets: ackVault).loadShadow()
    try check(ackReloaded?.records[1].jar == saved, "write-then-error resolves to the new durable state")

    let unknownVault = TransactionFaultVault()
    let unknownOuter = PiliAccountEnvelopeStagingStore(secrets: unknownVault)
    let unknownStore = PiliAccountEnvelopeTransactionStore(vault: unknownOuter)
    try await unknownOuter.importShadow(codec.encode(base))
    await unknownVault.arm(.pointerReadAfter)
    do {
      _ = try await unknownStore.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
      throw TransactionFixtureError.failed("unknown acknowledgment not surfaced")
    } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
    try check(await unknownVault.recordCount() == 2, "unknown publication preserves both records")
    let unknownReloaded = try await PiliAccountEnvelopeStagingStore(secrets: unknownVault).loadShadow()
    try check(unknownReloaded?.records[1].jar == cleared, "unknown acknowledgment resolves from durable pointer")

    // The operation gate fences actor reentry while a publication is awaiting.
    let fencedVault = TransactionFaultVault()
    let fencedOuter = PiliAccountEnvelopeStagingStore(secrets: fencedVault)
    let fencedStore = PiliAccountEnvelopeTransactionStore(vault: fencedOuter)
    try await fencedOuter.importShadow(codec.encode(base))
    await fencedVault.pauseWrite()
    let pending = Task {
      try await fencedStore.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
    }
    for _ in 0..<1000 {
      if await fencedVault.isPaused() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    if !(await fencedVault.isPaused()) {
      pending.cancel(); throw TransactionFixtureError.failed("transaction did not suspend")
    }
    do {
      _ = try await fencedStore.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
      throw TransactionFixtureError.failed("reentrant transaction admitted")
    } catch PiliAccountShadowTransactionError.operationInProgress { checks += 1 }
    await fencedVault.resume()
    _ = try await pending.value
    let fencedReloaded = try await PiliAccountEnvelopeStagingStore(secrets: fencedVault).loadShadow()
    try check(fencedReloaded?.records[1].jar == cleared, "fenced transaction publishes once")

    // Cancellation before pointer publication keeps the previous durable state.
    await fencedVault.pauseWrite()
    let cancelled = Task {
      try await fencedStore.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
    }
    for _ in 0..<1000 {
      if await fencedVault.isPaused() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    if !(await fencedVault.isPaused()) {
      cancelled.cancel(); throw TransactionFixtureError.failed("cancel transaction did not suspend")
    }
    cancelled.cancel()
    await fencedVault.resume()
    do {
      _ = try await cancelled.value
      throw TransactionFixtureError.failed("cancelled transaction published")
    } catch is CancellationError { checks += 1 }
    let cancelledReloaded = try await PiliAccountEnvelopeStagingStore(secrets: fencedVault).loadShadow()
    try check(cancelledReloaded?.records[1].jar == cleared, "cancellation keeps previous durable jar")
    print("\(checks) native account envelope transaction checks passed")
  }
}
