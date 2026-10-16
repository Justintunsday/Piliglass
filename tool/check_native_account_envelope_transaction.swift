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

/// Test-tool only: drives the deterministic pause of one transaction at the
/// production pre-publication seam. It never injects values, gates or
/// failures; it only suspends the calling transaction until the test resumes
/// it, and it surfaces a transaction that finished before reaching the seam
/// instead of waiting forever for a pause signal.
private actor PrePublicationPauser {
  enum Outcome: Sendable, Equatable { case paused, completedBeforePause(String) }
  private var reached = false
  private var earlyExit: String?
  private var suspended: CheckedContinuation<Void, Never>?
  private var pauseObserver: CheckedContinuation<Outcome, Never>?
  private var registrationObserver: CheckedContinuation<Void, Never>?

  func suspendOnce() async {
    guard !reached else { return }
    reached = true
    registrationObserver?.resume()
    registrationObserver = nil
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      suspended = continuation
      pauseObserver?.resume(returning: .paused)
      pauseObserver = nil
    }
  }

  func waitUntilPaused() async -> Outcome {
    if let earlyExit { return .completedBeforePause(earlyExit) }
    if reached { return .paused }
    return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
      pauseObserver = continuation
      registrationObserver?.resume()
      registrationObserver = nil
    }
  }

  /// Test-tool only: returns once a later pause or completion signal cannot be
  /// missed because the observer is registered (or the seam already resolved).
  /// It makes the registration-before-completion ordering deterministic in the
  /// direct regressions without sleeps.
  func waitForObserverRegistration() async {
    if pauseObserver != nil || reached || earlyExit != nil { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      registrationObserver = continuation
    }
  }

  func resume() {
    suspended?.resume()
    suspended = nil
  }

  func completedBeforePause(_ message: String) {
    guard !reached else { return }
    earlyExit = message
    registrationObserver?.resume()
    registrationObserver = nil
    pauseObserver?.resume(returning: .completedBeforePause(message))
    pauseObserver = nil
  }
}

/// Test-tool only one-shot gate: a deterministic way to hold a synthetic task
/// before its terminal result without sleeps or scheduling assumptions.
private actor CompletionGate {
  private var opened = false
  private var waiter: CheckedContinuation<Void, Never>?

  func wait() async {
    if opened { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiter = continuation
    }
  }

  func open() {
    opened = true
    waiter?.resume()
    waiter = nil
  }
}

/// Test-tool only transparent forwarding counter over the real Keychain
/// backend: every operation delegates unchanged and successful writes are
/// counted, so a rejected or cancelled attempt can be observed to perform zero
/// durable writes without injecting or reading any pointer value.
private actor ForwardingWriteCountingSecrets: PiliAccountSecretStore {
  private let inner: PiliAccountKeychainSecretStore
  private var writeCount = 0

  init(_ inner: PiliAccountKeychainSecretStore) { self.inner = inner }
  func writes() -> Int { writeCount }
  func read(_ key: String) async throws -> Data? { try await inner.read(key) }
  func write(_ data: Data, key: String) async throws {
    try await inner.write(data, key: key)
    writeCount += 1
  }
  func remove(_ key: String) async throws { try await inner.remove(key) }
}

@main private struct AccountEnvelopeTransactionChecks {
  private static func raceSlot(_ purpose: PiliAccountPurpose) -> Int {
    switch purpose {
    case .main: return 0
    case .heartbeat: return 1
    case .recommend: return 2
    case .video: return 3
    }
  }

  /// Mirrors the production `replace` carry rule: every field except the
  /// explicit overrides is copied and schema 3 keeps the monotonic high-water.
  private static func raceShadow(_ current: PiliAccountLiveMemoryShadow,
                                 records: [PiliAccountLiveMemoryRecord]? = nil,
                                 selections: [Int]? = nil,
                                 history: Int? = nil) -> PiliAccountLiveMemoryShadow {
    let resolvedHighWater: Int64? = current.schemaVersion == 3
      ? max(current.generationHighWater ?? 0, current.effectiveGenerationHighWater)
      : nil
    return PiliAccountLiveMemoryShadow(
      schemaVersion: current.schemaVersion,
      scope: current.scope, identityScope: current.identityScope,
      revision: current.revision,
      durableIdentityConfigured: current.durableIdentityConfigured,
      durabilityVerified: current.durabilityVerified,
      authoritySwitchAllowed: current.authoritySwitchAllowed,
      nativeWritesAllowed: current.nativeWritesAllowed,
      records: records ?? current.records,
      storedOrder: current.storedOrder,
      ownerOrder: current.ownerOrder,
      selectionPurposes: current.selectionPurposes,
      selections: selections ?? current.selections,
      history: history ?? current.history,
      generationHighWater: resolvedHighWater)
  }

  /// Independently derives the expected `applyPurposeChange` result from the
  /// fixture and the documented primitive: append-if-missing on the selected
  /// record, the explicitly named previous holder loses the purpose in the
  /// same candidate, the slot and history follow the existing policy, and
  /// every other field is carried. It never reads the produced winner.
  private static func expectedPurposeChange(_ current: PiliAccountLiveMemoryShadow,
                                            index: Int, purpose: PiliAccountPurpose,
                                            previousIndex: Int?)
    -> PiliAccountLiveMemoryShadow {
    var records = current.records
    let selected = records[index]
    if !selected.persistedPurposes.contains(purpose) {
      records[index] = PiliAccountLiveMemoryRecord(
        record: selected.record, generation: selected.generation,
        storageKeyUnits: selected.storageKeyUnits, mid: selected.mid,
        isLogin: selected.isLogin, accessKeyUnits: selected.accessKeyUnits,
        refreshTokenUnits: selected.refreshTokenUnits,
        persistedPurposes: selected.persistedPurposes + [purpose],
        activated: selected.activated, jar: selected.jar,
        durableIdentity: selected.durableIdentity)
    }
    if let previousIndex, previousIndex != index {
      let previous = records[previousIndex]
      if previous.persistedPurposes.contains(purpose) {
        records[previousIndex] = PiliAccountLiveMemoryRecord(
          record: previous.record, generation: previous.generation,
          storageKeyUnits: previous.storageKeyUnits, mid: previous.mid,
          isLogin: previous.isLogin, accessKeyUnits: previous.accessKeyUnits,
          refreshTokenUnits: previous.refreshTokenUnits,
          persistedPurposes: previous.persistedPurposes.filter { $0 != purpose },
          activated: previous.activated, jar: previous.jar,
          durableIdentity: previous.durableIdentity)
      }
    }
    var selections = current.selections
    selections[raceSlot(purpose)] = records[index].record
    let heartbeat = selections[1]
    let history = records[heartbeat].isLogin ? heartbeat : selections[0]
    return raceShadow(current, records: records, selections: selections, history: history)
  }

  /// Independently derives the expected `applyTemporarySelection` result.
  private static func expectedTemporarySelection(_ current: PiliAccountLiveMemoryShadow,
                                                 index: Int, purpose: PiliAccountPurpose)
    -> PiliAccountLiveMemoryShadow {
    var selections = current.selections
    selections[raceSlot(purpose)] = current.records[index].record
    let heartbeat = selections[1]
    let history = current.records[heartbeat].isLogin ? heartbeat : selections[0]
    return raceShadow(current, selections: selections, history: history)
  }

  /// Test-tool only: reports EVERY terminal result of the watched task to the
  /// pauser, success and failure alike, so an early completion can never leave
  /// `waitUntilPaused()` suspended forever. A result after the pause was
  /// reached is a no-op by the pauser's own guard.
  private static func completionWatcher<Success: Sendable>(
    pauser: PrePublicationPauser,
    task: Task<Success, any Error>
  ) -> Task<Void, Never> {
    Task {
      do {
        _ = try await task.value
        await pauser.completedBeforePause("transaction succeeded before the pause")
      } catch {
        await pauser.completedBeforePause(String(describing: error))
      }
    }
  }

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
    do {
      _ = try await fencedStore.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: PiliCookieUTF16(units: Array("reentrant-install".utf16)),
        mid: 1, generation: record.generation + 3000, accessKeyUnits: nil,
        refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: cleared))
      throw TransactionFixtureError.failed("reentrant install admitted")
    } catch PiliAccountShadowTransactionError.operationInProgress { checks += 1 }
    do {
      _ = try await fencedStore.applyDelete(
        recordKeyUnits: key, expectedGeneration: record.generation)
      throw TransactionFixtureError.failed("reentrant delete admitted")
    } catch PiliAccountShadowTransactionError.operationInProgress { checks += 1 }
    do {
      _ = try await fencedStore.applyImport([PiliAccountShadowInstall(
        storageKeyUnits: PiliCookieUTF16(units: Array("reentrant-import".utf16)),
        mid: 1, generation: record.generation + 4000, accessKeyUnits: nil,
        refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: cleared)])
      throw TransactionFixtureError.failed("reentrant import admitted")
    } catch PiliAccountShadowTransactionError.operationInProgress { checks += 1 }
    do {
      _ = try await fencedStore.applyBuvidSeed(recordKeyUnits: key,
        expectedGeneration: record.generation,
        valueUnits: PiliCookieUTF16(units: Array("reentrant-buvid".utf16)),
        nowMicroseconds: now)
      throw TransactionFixtureError.failed("reentrant buvid seed admitted")
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
    // generations/revision stay untouched. It is a low-level primitive: the
    // caller names the previous holder; no global uniqueness is implied, and
    // legacy captures may hold the same purpose on several records.
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

      // Primitive preconditions: previous is caller-named and never scanned.
      guard let primitiveShadow = try await purposeVault.loadShadow() else {
        throw TransactionFixtureError.failed("missing purpose primitive shadow")
      }
      try check(primitiveShadow.records[1].persistedPurposes.contains(purpose),
                "primitive fixture holds the purpose on the other record")
      _ = try await purposeStore.applyPurposeChange(
        recordKeyUnits: secondKey, expectedGeneration: base.records[2].generation,
        purpose: purpose, previousKeyUnits: nil, previousExpectedGeneration: nil)
      let afterOmittedPrevious = try await purposeVault.loadShadow()
      try check(afterOmittedPrevious?.records[1].persistedPurposes.contains(purpose) == true &&
        afterOmittedPrevious?.records[2].persistedPurposes.contains(purpose) == true,
        "omitted previous is documented: the unnamed holder keeps the purpose")
      guard let nonHeldPurpose = PiliAccountPurpose.allCases.first(where: {
        !primitiveShadow.records[1].persistedPurposes.contains($0)
      }) else {
        throw TransactionFixtureError.failed("no purpose left for the non-holder case")
      }
      _ = try await purposeStore.applyPurposeChange(
        recordKeyUnits: secondKey, expectedGeneration: base.records[2].generation,
        purpose: nonHeldPurpose, previousKeyUnits: key,
        previousExpectedGeneration: record.generation)
      let afterNonHolder = try await purposeVault.loadShadow()
      try check(afterNonHolder?.records[1].persistedPurposes ==
        primitiveShadow.records[1].persistedPurposes,
        "a named previous that does not hold the purpose is left untouched")

      // Close/reopen publishes and reads back the complete envelope.
      guard let beforeReopenPurpose = try await purposeVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing purpose reopen snapshot")
      }
      let reopenedPurposeVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: purposeNamespace))
      try check(try await reopenedPurposeVault.loadShadow() == beforeReopenPurpose.envelope,
                "purpose changes survive real Keychain close/reopen")

      // Adding a purpose must still fit the encoded byte budget.
      let tightNamespace = UUID()
      let tightVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: tightNamespace))
      let tightSeedStore = PiliAccountEnvelopeTransactionStore(vault: tightVault)
      do {
        try await tightVault.importShadow(codec.encode(base))
        _ = try await tightSeedStore.adoptMissingIdentities()
        guard let tightShadow = try await tightVault.loadShadow() else {
          throw TransactionFixtureError.failed("missing tight budget shadow")
        }
        var tightTarget: (PiliCookieUTF16, Int64, PiliAccountPurpose)?
        for index in 1..<tightShadow.records.count {
          let record = tightShadow.records[index]
          if let missing = PiliAccountPurpose.allCases.first(where: {
            !record.persistedPurposes.contains($0)
          }), let recordKey = record.storageKeyUnits {
            tightTarget = (recordKey, record.generation, missing)
            break
          }
        }
        guard let tightTarget else {
          throw TransactionFixtureError.failed("no purpose slot for the byte budget case")
        }
        let currentBytes = try codec.encode(tightShadow).count
        var tightLimits = PiliOrderedCookieArchiveLimits.standard
        tightLimits.maximumEncodedBytes = currentBytes
        let tightStore = PiliAccountEnvelopeTransactionStore(vault: tightVault, limits: tightLimits)
        guard let tightBefore = try await tightVault.loadShadowSnapshot() else {
          throw TransactionFixtureError.failed("missing tight budget snapshot")
        }
        do {
          _ = try await tightStore.applyPurposeChange(
            recordKeyUnits: tightTarget.0, expectedGeneration: tightTarget.1,
            purpose: tightTarget.2, previousKeyUnits: nil, previousExpectedGeneration: nil)
          throw TransactionFixtureError.failed("purpose addition beyond the byte budget accepted")
        } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
        let tightAfter = try await tightVault.loadShadowSnapshot()
        try check(tightAfter?.transactionID == tightBefore.transactionID &&
          tightAfter?.envelope == tightBefore.envelope,
          "byte-budget rejection publishes nothing")
        try await tightVault.discardShadow()
      } catch {
        try? await tightVault.discardShadow()
        throw error
      }

      try await purposeVault.discardShadow()
    } catch {
      try? await purposeVault.discardShadow()
      throw error
    }

    // R51 targeted race: `applyPurposeChange` keeps its captured previous
    // pointer and its validated candidate while a legitimate competing
    // publisher on the SAME vault instance publishes a newer envelope; on
    // resume the real staging compare-and-publish must reject the stale
    // transform with `staleTransaction`, publish nothing and leave the
    // winner's complete state. The expectation is derived independently from
    // the fixture/primitive and never read back from the winner.
    let raceNamespace = UUID()
    let raceSecrets = ForwardingWriteCountingSecrets(
      PiliAccountKeychainSecretStore(stagingNamespace: raceNamespace))
    let raceVault = PiliAccountEnvelopeStagingStore(secrets: raceSecrets)
    let raceStoreA = PiliAccountEnvelopeTransactionStore(vault: raceVault)
    let raceStoreB = PiliAccountEnvelopeTransactionStore(vault: raceVault)
    do {
      try await raceVault.importShadow(codec.encode(base))
      guard let raceKey = base.records[2].storageKeyUnits,
            let raceBaseline = try await raceVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("race fixture incomplete")
      }
      try check(raceBaseline.envelope == base, "race baseline is the imported fixture")
      let initialSecond = base.records[2].persistedPurposes
      guard let racePurposeA = PiliAccountPurpose.allCases.first(where: {
        !initialSecond.contains($0)
      }), let racePurposeB = PiliAccountPurpose.allCases.first(where: {
        !initialSecond.contains($0) && $0 != racePurposeA
      }) else {
        throw TransactionFixtureError.failed("race purposes missing")
      }

      // C1: A pauses at the pre-publication seam; B publishes the winner
      // through the real API; A resumes into the real CAS.
      let racePauser = PrePublicationPauser()
      await raceStoreA.setPrePublicationDeliveryHook { await racePauser.suspendOnce() }
      let raceTask = Task {
        try await raceStoreA.applyPurposeChange(
          recordKeyUnits: raceKey, expectedGeneration: base.records[2].generation,
          purpose: racePurposeA, previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let raceWatcher = completionWatcher(pauser: racePauser, task: raceTask)
      var winnerReceipt: PiliAccountEnvelopeStagingReceipt?
      var expectedWinner: PiliAccountLiveMemoryShadow?
      do {
        switch await racePauser.waitUntilPaused() {
        case .paused: break
        case .completedBeforePause(let message):
          throw TransactionFixtureError.failed("race transaction finished before the pause: \(message)")
        }
        let writesAtPause = await raceSecrets.writes()
        let winnerReceiptValue = try await raceStoreB.applyPurposeChange(
          recordKeyUnits: raceKey, expectedGeneration: base.records[2].generation,
          purpose: racePurposeB, previousKeyUnits: nil, previousExpectedGeneration: nil)
        winnerReceipt = winnerReceiptValue
        let writesAfterWinner = await raceSecrets.writes()
        try check(writesAfterWinner > writesAtPause,
                  "competing publisher performs durable writes during the pause")
        guard let winner = try await raceVault.loadShadowSnapshot() else {
          throw TransactionFixtureError.failed("missing race winner snapshot")
        }
        let expectedWinnerValue = expectedPurposeChange(
          base, index: 2, purpose: racePurposeB, previousIndex: nil)
        expectedWinner = expectedWinnerValue
        try check(winner.transactionID == winnerReceiptValue.transactionID,
                  "winner pointer names the competing publication")
        try check(winner.envelope == expectedWinnerValue,
                  "winner equals the independently derived purpose-change envelope")
        await racePauser.resume()
        do {
          _ = try await raceTask.value
          throw TransactionFixtureError.failed("stale purpose transform published over the winner")
        } catch PiliAccountEnvelopeStagingError.staleTransaction { checks += 1 }
        try check(await raceStoreA.pendingUnresolvedPublication == nil,
                  "stale rejection arms no unknown fence")
        try check(try await raceVault.loadRecoveryJournal() == nil,
                  "stale rejection writes no recovery journal")
        try check(await raceSecrets.writes() == writesAfterWinner,
                  "stale rejection performs zero durable writes")
        guard let afterStale = try await raceVault.loadShadowSnapshot() else {
          throw TransactionFixtureError.failed("missing post-stale snapshot")
        }
        try check(afterStale.transactionID == winnerReceiptValue.transactionID,
                  "stale rejection keeps the winning pointer")
        try check(afterStale.envelope == expectedWinnerValue,
                  "stale rejection leaves the complete winner state")
        await raceWatcher.value
      } catch {
        await racePauser.resume()
        _ = try? await raceTask.value
        await raceWatcher.value
        await raceStoreA.setPrePublicationDeliveryHook(nil)
        throw error
      }
      guard let confirmedWinnerReceipt = winnerReceipt, let confirmedWinner = expectedWinner else {
        throw TransactionFixtureError.failed("C1 race produced no verified winner")
      }

      // Cancellation control on the same seam: A paused with no competing
      // publisher. The continuation is not cancellation-aware, so the test
      // cancels and then explicitly resumes; the staging CAS passes first and
      // the existing checkCancellation surfaces exactly CancellationError with
      // no receipt, no durable write and no fence before the later valid write.
      let cancelPauser = PrePublicationPauser()
      await raceStoreA.setPrePublicationDeliveryHook { await cancelPauser.suspendOnce() }
      let cancelTask = Task {
        try await raceStoreA.applyPurposeChange(
          recordKeyUnits: raceKey, expectedGeneration: base.records[2].generation,
          purpose: racePurposeA, previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let cancelWatcher = completionWatcher(pauser: cancelPauser, task: cancelTask)
      do {
        switch await cancelPauser.waitUntilPaused() {
        case .paused: break
        case .completedBeforePause(let message):
          throw TransactionFixtureError.failed("cancel control finished before the pause: \(message)")
        }
        let writesBeforeCancel = await raceSecrets.writes()
        cancelTask.cancel()
        await cancelPauser.resume()
        do {
          _ = try await cancelTask.value
          throw TransactionFixtureError.failed("cancelled paused transaction published")
        } catch is CancellationError { checks += 1 }
        try check(await raceStoreA.pendingUnresolvedPublication == nil,
                  "cancellation arms no unknown fence")
        try check(try await raceVault.loadRecoveryJournal() == nil,
                  "cancellation writes no recovery journal")
        try check(await raceSecrets.writes() == writesBeforeCancel,
                  "cancellation performs zero durable writes")
        guard let afterCancel = try await raceVault.loadShadowSnapshot() else {
          throw TransactionFixtureError.failed("missing post-cancel snapshot")
        }
        try check(afterCancel.transactionID == confirmedWinnerReceipt.transactionID &&
                  afterCancel.envelope == confirmedWinner,
                  "cancellation leaves the durable winner untouched")
        await cancelWatcher.value
      } catch {
        await cancelPauser.resume()
        _ = try? await cancelTask.value
        await cancelWatcher.value
        await raceStoreA.setPrePublicationDeliveryHook(nil)
        throw error
      }
      await raceStoreA.setPrePublicationDeliveryHook(nil)

      // A later valid publication merges from the winner: B's purpose is
      // preserved, A's stale candidate is never reused and the receipt names
      // the fresh pointer/record/identity with both authority gates false.
      let mergeReceipt = try await raceStoreA.applyPurposeChange(
        recordKeyUnits: raceKey, expectedGeneration: base.records[2].generation,
        purpose: racePurposeA, previousKeyUnits: nil, previousExpectedGeneration: nil)
      guard let afterMerge = try await raceVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("missing post-merge snapshot")
      }
      let expectedMerge = expectedPurposeChange(
        confirmedWinner, index: 2, purpose: racePurposeA, previousIndex: nil)
      try check(mergeReceipt.transactionID == afterMerge.transactionID,
                "later publication names the fresh pointer")
      try check(mergeReceipt.record == base.records[2].record,
                "later publication names the exact record")
      try check(mergeReceipt.durableIdentity == base.records[2].durableIdentity,
                "later publication carries the record's durable identity")
      try check(mergeReceipt.nativeWritesAllowed == false &&
                mergeReceipt.authoritySwitchAllowed == false,
                "later publication still grants no authority")
      try check(afterMerge.envelope == expectedMerge,
                "later publication merges the winner's purpose in Dart order")
      try check(afterMerge.envelope.records[2].generation == base.records[2].generation &&
                afterMerge.envelope.revision == base.revision,
                "later publication keeps capture-local identity unrenumbered")

      // Reopen only after every racing task has settled: a fresh
      // Security.framework instance over the same namespace reads the merge.
      let reopenedRaceVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: raceNamespace))
      try check(try await reopenedRaceVault.loadShadow() == expectedMerge,
                "fresh same-namespace Keychain instance reads the final winner")
      try await raceVault.discardShadow()
    } catch {
      await raceStoreA.setPrePublicationDeliveryHook(nil)
      try? await raceVault.discardShadow()
      throw error
    }

    // C4 variant: the competing publisher moves the slot with a temporary
    // selection instead of a purpose change; the resumed stale transform must
    // be rejected the same way and the winner's slot/history stay untouched.
    let tempNamespace = UUID()
    let tempSecrets = ForwardingWriteCountingSecrets(
      PiliAccountKeychainSecretStore(stagingNamespace: tempNamespace))
    let tempVault = PiliAccountEnvelopeStagingStore(secrets: tempSecrets)
    let tempStoreA = PiliAccountEnvelopeTransactionStore(vault: tempVault)
    let tempStoreB = PiliAccountEnvelopeTransactionStore(vault: tempVault)
    do {
      try await tempVault.importShadow(codec.encode(base))
      guard let tempKey = base.records[2].storageKeyUnits,
            let tempBaseline = try await tempVault.loadShadowSnapshot() else {
        throw TransactionFixtureError.failed("temporary race fixture incomplete")
      }
      try check(tempBaseline.envelope == base, "temporary race baseline is the imported fixture")
      let tempInitialSecond = base.records[2].persistedPurposes
      guard let tempPurposeA = PiliAccountPurpose.allCases.first(where: {
        !tempInitialSecond.contains($0)
      }), let tempSelectionPurpose = PiliAccountPurpose.allCases.first(where: {
        !tempInitialSecond.contains($0) && $0 != tempPurposeA
      }) else {
        throw TransactionFixtureError.failed("temporary race purposes missing")
      }
      let tempPauser = PrePublicationPauser()
      await tempStoreA.setPrePublicationDeliveryHook { await tempPauser.suspendOnce() }
      let tempTask = Task {
        try await tempStoreA.applyPurposeChange(
          recordKeyUnits: tempKey, expectedGeneration: base.records[2].generation,
          purpose: tempPurposeA, previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let tempWatcher = completionWatcher(pauser: tempPauser, task: tempTask)
      do {
        switch await tempPauser.waitUntilPaused() {
        case .paused: break
        case .completedBeforePause(let message):
          throw TransactionFixtureError.failed("temporary race finished before the pause: \(message)")
        }
        let tempWritesAtPause = await tempSecrets.writes()
        let tempWinnerReceipt = try await tempStoreB.applyTemporarySelection(
          recordKeyUnits: tempKey, expectedGeneration: base.records[2].generation,
          purpose: tempSelectionPurpose)
        let tempWritesAfterWinner = await tempSecrets.writes()
        try check(tempWritesAfterWinner > tempWritesAtPause,
                  "temporary competing publisher performs durable writes during the pause")
        guard let tempWinner = try await tempVault.loadShadowSnapshot() else {
          throw TransactionFixtureError.failed("missing temporary race winner snapshot")
        }
        let expectedTemporaryWinner = expectedTemporarySelection(
          base, index: 2, purpose: tempSelectionPurpose)
        try check(tempWinner.transactionID == tempWinnerReceipt.transactionID,
                  "temporary winner pointer names the competing publication")
        try check(tempWinner.envelope == expectedTemporaryWinner,
                  "temporary winner equals the independently derived selection envelope")
        await tempPauser.resume()
        do {
          _ = try await tempTask.value
          throw TransactionFixtureError.failed("stale purpose transform published over the temporary winner")
        } catch PiliAccountEnvelopeStagingError.staleTransaction { checks += 1 }
        try check(await tempStoreA.pendingUnresolvedPublication == nil,
                  "temporary race arms no unknown fence")
        try check(try await tempVault.loadRecoveryJournal() == nil,
                  "temporary race writes no recovery journal")
        try check(await tempSecrets.writes() == tempWritesAfterWinner,
                  "temporary race rejection performs zero durable writes")
        guard let tempAfterStale = try await tempVault.loadShadowSnapshot() else {
          throw TransactionFixtureError.failed("missing temporary post-stale snapshot")
        }
        try check(tempAfterStale.transactionID == tempWinnerReceipt.transactionID &&
                  tempAfterStale.envelope == expectedTemporaryWinner,
                  "temporary race rejection leaves the complete winner state")
        await tempWatcher.value
      } catch {
        await tempPauser.resume()
        _ = try? await tempTask.value
        await tempWatcher.value
        await tempStoreA.setPrePublicationDeliveryHook(nil)
        throw error
      }
      await tempStoreA.setPrePublicationDeliveryHook(nil)
      try await tempVault.discardShadow()
    } catch {
      await tempStoreA.setPrePublicationDeliveryHook(nil)
      try? await tempVault.discardShadow()
      throw error
    }

    // R53 direct regressions: every terminal result (success and failure) is
    // reported through the shared completion watcher in both orderings, an
    // early success can never leave `waitUntilPaused()` suspended, and an
    // explicitly resumed one-shot pause keeps completing normally. The tasks
    // are real store operations on a dedicated namespace; the CompletionGate
    // holds them deterministically without sleeps or Task.yield.
    let pauserNamespace = UUID()
    let pauserVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: pauserNamespace))
    let pauserStore = PiliAccountEnvelopeTransactionStore(vault: pauserVault)
    do {
      try await pauserVault.importShadow(codec.encode(base))
      guard let pauserKey = base.records[2].storageKeyUnits else {
        throw TransactionFixtureError.failed("pauser regression key missing")
      }
      let pauserInitial = base.records[2].persistedPurposes
      let pauserPurposes = PiliAccountPurpose.allCases.filter { !pauserInitial.contains($0) }
      guard pauserPurposes.count >= 3 else {
        throw TransactionFixtureError.failed("pauser regression purposes missing")
      }
      let missingPauserKey = PiliCookieUTF16(units: Array("pauser-missing".utf16))

      // 1. Early success with completion before the observer registers.
      let earlySuccess = PrePublicationPauser()
      let earlySuccessTask = Task {
        try await pauserStore.applyPurposeChange(
          recordKeyUnits: pauserKey, expectedGeneration: base.records[2].generation,
          purpose: pauserPurposes[0], previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let earlySuccessWatcher = completionWatcher(pauser: earlySuccess, task: earlySuccessTask)
      _ = try await earlySuccessTask.value
      await earlySuccessWatcher.value
      switch await earlySuccess.waitUntilPaused() {
      case .paused:
        throw TransactionFixtureError.failed("completed early success was reported as a pause")
      case .completedBeforePause(let message):
        try check(message.contains("succeeded"), "early success is reported through the helper")
      }
      let afterEarlySuccess = try await pauserVault.loadShadow()
      try check(afterEarlySuccess?.records[2].persistedPurposes.contains(pauserPurposes[0]) == true,
                "early success regression really published")

      // 2. Early failure with completion before the observer registers.
      let earlyFailure = PrePublicationPauser()
      let earlyFailureTask = Task {
        try await pauserStore.applyPurposeChange(
          recordKeyUnits: missingPauserKey, expectedGeneration: base.records[2].generation,
          purpose: pauserPurposes[1], previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let earlyFailureWatcher = completionWatcher(pauser: earlyFailure, task: earlyFailureTask)
      do {
        _ = try await earlyFailureTask.value
        throw TransactionFixtureError.failed("early failure regression unexpectedly succeeded")
      } catch PiliAccountShadowTransactionError.unknownRecordKey { checks += 1 }
      await earlyFailureWatcher.value
      switch await earlyFailure.waitUntilPaused() {
      case .paused:
        throw TransactionFixtureError.failed("completed early failure was reported as a pause")
      case .completedBeforePause(let message):
        try check(message.contains("unknownRecordKey"),
                  "early failure keeps its exact error description")
      }

      // 3. Early failure with the observer registered first.
      let registeredFailure = PrePublicationPauser()
      let failureGate = CompletionGate()
      let gatedFailureTask = Task {
        await failureGate.wait()
        return try await pauserStore.applyPurposeChange(
          recordKeyUnits: missingPauserKey, expectedGeneration: base.records[2].generation,
          purpose: pauserPurposes[1], previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let gatedFailureWatcher = completionWatcher(pauser: registeredFailure, task: gatedFailureTask)
      let registeredFailureOutcome = Task { await registeredFailure.waitUntilPaused() }
      await registeredFailure.waitForObserverRegistration()
      await failureGate.open()
      await gatedFailureWatcher.value
      switch await registeredFailureOutcome.value {
      case .paused:
        throw TransactionFixtureError.failed("observer-first failure was reported as a pause")
      case .completedBeforePause(let message):
        try check(message.contains("unknownRecordKey"), "observer-first failure notification is exact")
      }

      // 4. Early success with the observer registered first.
      let registeredSuccess = PrePublicationPauser()
      let successGate = CompletionGate()
      let gatedSuccessTask = Task {
        await successGate.wait()
        return try await pauserStore.applyPurposeChange(
          recordKeyUnits: pauserKey, expectedGeneration: base.records[2].generation,
          purpose: pauserPurposes[1], previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let gatedSuccessWatcher = completionWatcher(pauser: registeredSuccess, task: gatedSuccessTask)
      let registeredSuccessOutcome = Task { await registeredSuccess.waitUntilPaused() }
      await registeredSuccess.waitForObserverRegistration()
      await successGate.open()
      await gatedSuccessWatcher.value
      switch await registeredSuccessOutcome.value {
      case .paused:
        throw TransactionFixtureError.failed("observer-first success was reported as a pause")
      case .completedBeforePause(let message):
        try check(message.contains("succeeded"), "observer-first success notification is reported")
      }

      // 5. Normal pause and explicit resume (resume is idempotent).
      let resumePauser = PrePublicationPauser()
      await pauserStore.setPrePublicationDeliveryHook { await resumePauser.suspendOnce() }
      let pausedTask = Task {
        try await pauserStore.applyPurposeChange(
          recordKeyUnits: pauserKey, expectedGeneration: base.records[2].generation,
          purpose: pauserPurposes[2], previousKeyUnits: nil, previousExpectedGeneration: nil)
      }
      let pausedWatcher = completionWatcher(pauser: resumePauser, task: pausedTask)
      switch await resumePauser.waitUntilPaused() {
      case .paused: checks += 1
      case .completedBeforePause:
        throw TransactionFixtureError.failed("pending pause was reported as completed")
      }
      await resumePauser.resume()
      await resumePauser.resume()
      _ = try await pausedTask.value
      await pausedWatcher.value
      await pauserStore.setPrePublicationDeliveryHook(nil)
      switch await resumePauser.waitUntilPaused() {
      case .paused: checks += 1
      case .completedBeforePause:
        throw TransactionFixtureError.failed("resumed one-shot pause lost its state")
      }
      let afterResume = try await pauserVault.loadShadow()
      try check(afterResume?.records[2].persistedPurposes.contains(pauserPurposes[2]) == true,
                "normal pause/resume regression really published")
      try await pauserVault.discardShadow()
    } catch {
      await pauserStore.setPrePublicationDeliveryHook(nil)
      try? await pauserVault.discardShadow()
      throw error
    }

    print("\(checks) native account envelope transaction checks passed")
  }
}
