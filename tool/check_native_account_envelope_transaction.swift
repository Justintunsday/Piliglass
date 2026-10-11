import Foundation

private enum TransactionFixtureError: Error { case failed(String), injected }

private actor TransactionFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable { case pointerWriteAfter, pointerReadAfter }
  private var values: [String: Data] = [:]
  private var fault: Fault?
  private var published = false
  private var pause = false
  private var suspended: CheckedContinuation<Void, Never>?
  private var pauseObserver: CheckedContinuation<Void, Never>?
  private let pointer = "account-envelope-shadow-manifest-v2"

  func arm(_ next: Fault) { fault = next; published = false }
  func pauseWrite() { pause = true }
  func waitUntilPaused() async {
    if suspended != nil { return }
    await withCheckedContinuation { pauseObserver = $0 }
  }
  func resume() { suspended?.resume(); suspended = nil }
  func recordCount() -> Int {
    values.keys.filter { $0.hasPrefix("account-envelope-shadow-v2.") }.count
  }

  func read(_ key: String) throws -> Data? {
    if key == pointer, published, fault == .pointerReadAfter { fault = nil; throw TransactionFixtureError.injected }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    if pause {
      pause = false
      await withCheckedContinuation {
        suspended = $0
        pauseObserver?.resume()
        pauseObserver = nil
      }
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

    // A transform made from an old snapshot must not replace an intervening
    // direct import, even when capture-local revision/generation are unchanged.
    // This uses the actual shared-vault CAS path used by TransactionStore.
    let conflictSecrets = TransactionFaultVault()
    let conflictVault = PiliAccountEnvelopeStagingStore(secrets: conflictSecrets)
    try await conflictVault.importShadow(codec.encode(base))
    guard let obsolete = try await conflictVault.loadShadowSnapshot() else {
      throw TransactionFixtureError.failed("missing conflict snapshot")
    }
    let conflictStore = PiliAccountEnvelopeTransactionStore(vault: conflictVault)
    _ = try await conflictStore.applyCredentials(recordKeyUnits: key,
      expectedGeneration: record.generation,
      accessKeyUnits: PiliCookieUTF16(units: Array("intervening-credential".utf16)),
      refreshTokenUnits: nil)
    guard let intervening = try await conflictVault.loadShadowSnapshot() else {
      throw TransactionFixtureError.failed("missing intervening snapshot")
    }
    try check(intervening.transactionID != obsolete.transactionID,
              "each publication has an exact distinct pointer identity")
    // Publish the complete newer envelope through the direct-import API too,
    // covering a caller outside the transaction actor's own operation fence.
    let direct = try await conflictVault.importShadow(codec.encode(intervening.envelope))
    do {
      _ = try await conflictVault.importShadow(codec.encode(obsolete.envelope),
                                               expectedTransactionID: obsolete.transactionID)
      throw TransactionFixtureError.failed("stale snapshot silently replaced direct import")
    } catch PiliAccountEnvelopeStagingError.staleTransaction { checks += 1 }
    let afterConflict = try await conflictVault.loadShadowSnapshot()
    try check(afterConflict?.transactionID == direct.transactionID &&
      afterConflict?.envelope == intervening.envelope,
      "stale CAS leaves the entire newer direct import untouched")
    try check(afterConflict?.envelope.records[1].accessKeyUnits?.units ==
      Array("intervening-credential".utf16), "newer credentials survive rejected stale transform")

    // The operation gate fences actor reentry while a publication is awaiting.
    let fencedVault = TransactionFaultVault()
    let fencedOuter = PiliAccountEnvelopeStagingStore(secrets: fencedVault)
    let fencedStore = PiliAccountEnvelopeTransactionStore(vault: fencedOuter)
    try await fencedOuter.importShadow(codec.encode(base))
    await fencedVault.pauseWrite()
    let pending = Task {
      try await fencedStore.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
    }
    await fencedVault.waitUntilPaused()
    do {
      _ = try await fencedStore.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
      throw TransactionFixtureError.failed("reentrant transaction admitted")
    } catch PiliAccountShadowTransactionError.operationInProgress { checks += 1 }
    do {
      _ = try await fencedStore.applyPurposeChange(recordKeyUnits: key,
        expectedGeneration: record.generation, purpose: .recommend,
        previousKeyUnits: nil, previousExpectedGeneration: nil)
      throw TransactionFixtureError.failed("reentrant purpose change admitted")
    } catch PiliAccountShadowTransactionError.operationInProgress { checks += 1 }
    // A second transaction actor has a distinct wrapper fence, but the shared
    // vault rejects its read while A's durable publication is in progress.
    let competingStore = PiliAccountEnvelopeTransactionStore(vault: fencedOuter)
    do {
      _ = try await competingStore.applyCredentials(recordKeyUnits: key,
        expectedGeneration: record.generation,
        accessKeyUnits: PiliCookieUTF16(units: Array("must-not-publish".utf16)),
        refreshTokenUnits: nil)
      throw TransactionFixtureError.failed("second transaction actor overwrote pending publication")
    } catch PiliAccountEnvelopeStagingError.operationInProgress { checks += 1 }
    await fencedVault.resume()
    _ = try await pending.value
    let fencedReloaded = try await PiliAccountEnvelopeStagingStore(secrets: fencedVault).loadShadow()
    try check(fencedReloaded?.records[1].jar == cleared, "fenced transaction publishes once")
    try check(fencedReloaded?.records[1].accessKeyUnits == base.records[1].accessKeyUnits,
              "rejected second actor never changes credentials")

    // Cancellation before pointer publication keeps the previous durable state.
    await fencedVault.pauseWrite()
    let cancelled = Task {
      try await fencedStore.applyCookieDeleteAll(recordKeyUnits: key, expectedGeneration: record.generation)
    }
    await fencedVault.waitUntilPaused()
    cancelled.cancel()
    await fencedVault.resume()
    do {
      _ = try await cancelled.value
      throw TransactionFixtureError.failed("cancelled transaction published")
    } catch is CancellationError { checks += 1 }
    let cancelledReloaded = try await PiliAccountEnvelopeStagingStore(secrets: fencedVault).loadShadow()
    try check(cancelledReloaded?.records[1].jar == cleared, "cancellation keeps previous durable jar")

    // A persistent purpose change moves one purpose between two exact login
    // records inside a single candidate: selected gains (Dart append order),
    // previous loses, slots/history follow the existing policy, jars/order/
    // generations/revision stay untouched. Purpose-only growth is bounded by
    // the four fixed purposes, so the shared cumulative ledger is exercised by
    // the existing oversized-credentials case above.
    let purposeNamespace = UUID()
    let purposeVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: purposeNamespace))
    let purposeStore = PiliAccountEnvelopeTransactionStore(vault: purposeVault)
    do {
      try await purposeVault.importShadow(codec.encode(base))
      guard let importedSnapshot = try await purposeVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing purpose base snapshot")
      }
      let purpose = PiliAccountPurpose.recommend
      guard let secondKey = base.records[2].storageKeyUnits else {
        throw TransactionFixtureError.failed("second login storage key missing")
      }
      let initialFirst = base.records[1].persistedPurposes
      let initialSecond = base.records[2].persistedPurposes
      let addReceipt = try await purposeStore.applyPurposeChange(
        recordKeyUnits: secondKey, expectedGeneration: base.records[2].generation,
        purpose: purpose, previousKeyUnits: nil, previousExpectedGeneration: nil)
      try check(addReceipt.nativeWritesAllowed == false &&
        addReceipt.authoritySwitchAllowed == false, "purpose change never grants authority")
      try check(addReceipt.transactionID != importedSnapshot.transactionID,
                "purpose publication has a distinct exact pointer identity")
      let afterAdd = try await purposeVault.loadShadow()
      try check(afterAdd?.records[2].persistedPurposes ==
        (initialSecond.contains(purpose) ? initialSecond : initialSecond + [purpose]),
        "add-from-none appends the purpose in Dart order")
      try check(afterAdd?.records[2].persistedPurposes.filter { $0 == purpose }.count == 1,
                "add never duplicates an existing purpose")
      try check(afterAdd?.selections[2] == base.records[2].record,
                "add points the purpose slot at the selected record")

      let moveReceipt = try await purposeStore.applyPurposeChange(
        recordKeyUnits: key, expectedGeneration: record.generation,
        purpose: purpose, previousKeyUnits: secondKey,
        previousExpectedGeneration: base.records[2].generation)
      try check(moveReceipt.record == base.records[1].record,
                "move names the exact selected record")
      let afterMove = try await purposeVault.loadShadow()
      try check(afterMove?.records[1].persistedPurposes ==
        (initialFirst.contains(purpose) ? initialFirst : initialFirst + [purpose]),
        "selected purposes follow Dart append order")
      try check(afterMove?.records[2].persistedPurposes ==
        initialSecond.filter { $0 != purpose },
        "previous holder loses the purpose in the same candidate")
      try check(afterMove?.selections[2] == base.records[1].record,
                "move points the purpose slot at the selected record")
      try check(afterMove?.selections[0] == base.selections[0] &&
        afterMove?.selections[1] == base.selections[1] &&
        afterMove?.selections[3] == base.selections[3],
        "move leaves every other slot unchanged")
      let heartbeat = afterMove?.selections[1] ?? -1
      let expectedHistory = (afterMove?.records[heartbeat].isLogin ?? false)
        ? heartbeat : (afterMove?.selections[0] ?? -1)
      try check(afterMove?.history == expectedHistory,
                "history follows the existing derivation policy")
      try check(afterMove?.records[1].jar == base.records[1].jar &&
        afterMove?.records[2].jar == base.records[2].jar, "purpose change never touches jars")
      try check(afterMove?.storedOrder == base.storedOrder &&
        afterMove?.ownerOrder == base.ownerOrder, "purpose change preserves account order")
      try check(afterMove?.records[0] == base.records[0] &&
        afterMove?.records.count == base.records.count,
        "purpose change leaves anonymous and record count untouched")
      try check(afterMove?.revision == base.revision &&
        afterMove?.records[1].generation == base.records[1].generation &&
        afterMove?.records[2].generation == base.records[2].generation,
        "capture-local identity is not renumbered")

      _ = try await purposeStore.applyPurposeChange(
        recordKeyUnits: key, expectedGeneration: record.generation,
        purpose: purpose, previousKeyUnits: secondKey,
        previousExpectedGeneration: base.records[2].generation)
      let repeated = try await purposeVault.loadShadow()
      try check(repeated?.records[1].persistedPurposes == afterMove?.records[1].persistedPurposes &&
        repeated?.records[2].persistedPurposes == afterMove?.records[2].persistedPurposes,
        "repeated purpose change is idempotent")
      _ = try await purposeStore.applyPurposeChange(
        recordKeyUnits: key, expectedGeneration: record.generation,
        purpose: purpose, previousKeyUnits: key, previousExpectedGeneration: record.generation)
      let selfPrevious = try await purposeVault.loadShadow()
      try check(selfPrevious?.records[1].persistedPurposes == afterMove?.records[1].persistedPurposes,
                "same-record previous never removes the selected purpose")

      guard let beforeReject = try await purposeVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing purpose reject snapshot")
      }
      do {
        _ = try await purposeStore.applyPurposeChange(
          recordKeyUnits: key, expectedGeneration: record.generation,
          purpose: purpose, previousKeyUnits: PiliCookieUTF16(units: Array("missing".utf16)),
          previousExpectedGeneration: 1)
        throw TransactionFixtureError.failed("unknown previous record key accepted")
      } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
      do {
        _ = try await purposeStore.applyPurposeChange(
          recordKeyUnits: key, expectedGeneration: record.generation + 1,
          purpose: purpose, previousKeyUnits: nil, previousExpectedGeneration: nil)
        throw TransactionFixtureError.failed("stale selected generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await purposeStore.applyPurposeChange(
          recordKeyUnits: key, expectedGeneration: record.generation,
          purpose: purpose, previousKeyUnits: secondKey,
          previousExpectedGeneration: base.records[2].generation + 1)
        throw TransactionFixtureError.failed("stale previous generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      do {
        _ = try await purposeStore.applyPurposeChange(
          recordKeyUnits: key, expectedGeneration: record.generation,
          purpose: purpose, previousKeyUnits: secondKey,
          previousExpectedGeneration: nil)
        throw TransactionFixtureError.failed("missing previous generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      let afterReject = try await purposeVault.loadShadowSnapshot()
      try check(afterReject?.transactionID == beforeReject.transactionID &&
        afterReject?.envelope == beforeReject.envelope,
        "purpose rejections never publish a new candidate")
      try await purposeVault.discardShadow()
    } catch {
      try? await purposeVault.discardShadow()
      throw error
    }

    print("\(checks) native account envelope transaction checks passed")
  }
}
