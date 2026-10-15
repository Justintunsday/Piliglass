import Foundation

private enum QueueFixtureError: Error { case failed(String), injected }

/// Secret store with pause/unknown fault injection for the queue contract.
private actor QueueFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable {
    case pointerWriteAfter, pointerReadAfter, pointerWriteBefore
    case journalWriteBefore, journalWriteAfter
  }
  private var values: [String: Data] = [:]
  private var fault: Fault?
  private var published = false
  private var pause = false
  private var suspended: CheckedContinuation<Void, Never>?
  private var pauseObserver: CheckedContinuation<Void, Never>?
  private var manifestReadSkip = 0
  private var pauseManifestRead = false
  private var manifestReadSuspended: CheckedContinuation<Void, Never>?
  private var manifestReadObserver: CheckedContinuation<Void, Never>?
  private var pointerReadFailures = 0
  private var pointerReadFailSkip = 0
  private var journalReadFailures = 0
  private var journalReadFailSkip = 0
  private var journalRemoveFailures = 0
  private let pointer = "account-envelope-shadow-manifest-v2"
  private let recoveryJournalKey = "account-envelope-recovery-journal-v1"

  func arm(_ next: Fault) { fault = next; published = false }
  func pauseWrite() { pause = true }
  func waitUntilPaused() async {
    if suspended != nil { return }
    await withCheckedContinuation { pauseObserver = $0 }
  }
  func resume() { suspended?.resume(); suspended = nil }
  /// Pauses the next manifest read after `skip` further reads, so a queued
  /// write's publish-time comparison can be interleaved with an independent
  /// publication (CAS staleTransaction path).
  func pauseManifestReadAfter(_ skip: Int) {
    manifestReadSkip = skip
    pauseManifestRead = true
  }
  func waitUntilManifestReadPaused() async {
    if manifestReadSuspended != nil { return }
    await withCheckedContinuation { manifestReadObserver = $0 }
  }
  func resumeManifestRead() {
    manifestReadSuspended?.resume()
    manifestReadSuspended = nil
  }
  func isManifestReadPaused() -> Bool { manifestReadSuspended != nil }
  func isWritePaused() -> Bool { suspended != nil }
  /// Fails the pointer read that follows `skip` further pointer reads. The
  /// publish-time acknowledgment read is the second read of one attempt, so
  /// skip 1 targets exactly the unreadable-ack boundary.
  func failPointerReadAfter(_ skip: Int) {
    pointerReadFailSkip = skip
    pointerReadFailures = 1
  }
  func failPointerReadsForever() {
    pointerReadFailSkip = 0
    pointerReadFailures = Int.max
  }
  func allowPointerReads() {
    pointerReadFailSkip = 0
    pointerReadFailures = 0
  }
  /// Persistent journal read failure: recovery metadata must be unreadable
  /// without ever being treated as absent.
  func failJournalReadsForever() {
    journalReadFailSkip = 0
    journalReadFailures = Int.max
  }
  func allowJournalReads() {
    journalReadFailSkip = 0
    journalReadFailures = 0
  }
  /// Fails the journal read that follows `skip` further reads (or `failures`
  /// consecutive reads after the skip), so the entry pre-check read can pass
  /// and the post-write verification or clear-verification read can fail on
  /// its own without the pre-check masking it.
  func failJournalReadAfter(_ skip: Int, failures: Int = 1) {
    journalReadFailSkip = skip
    journalReadFailures = failures
  }
  /// Fails the next journal removals, so a journal that cannot be removed must
  /// keep its evidence and fail closed instead of being claimed clean.
  func failNextJournalRemovals(_ count: Int) { journalRemoveFailures = count }
  func recordCount() -> Int {
    values.keys.filter { $0.hasPrefix("account-envelope-shadow-v2.") }.count
  }

  func read(_ key: String) async throws -> Data? {
    if key == recoveryJournalKey, journalReadFailures > 0 {
      if journalReadFailSkip > 0 {
        journalReadFailSkip -= 1
      } else {
        if journalReadFailures != Int.max { journalReadFailures -= 1 }
        throw QueueFixtureError.injected
      }
    }
    if key == pointer {
      if pauseManifestRead {
        if manifestReadSkip > 0 {
          manifestReadSkip -= 1
        } else {
          pauseManifestRead = false
          await withCheckedContinuation {
            manifestReadSuspended = $0
            manifestReadObserver?.resume()
            manifestReadObserver = nil
          }
        }
      }
      if pointerReadFailures > 0 {
        if pointerReadFailSkip > 0 {
          pointerReadFailSkip -= 1
        } else {
          if pointerReadFailures != Int.max { pointerReadFailures -= 1 }
          throw QueueFixtureError.injected
        }
      }
      if published, fault == .pointerReadAfter {
        fault = nil
        throw QueueFixtureError.injected
      }
    }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    if pause, key != recoveryJournalKey {
      pause = false
      await withCheckedContinuation {
        suspended = $0
        pauseObserver?.resume()
        pauseObserver = nil
      }
    }
    if key == recoveryJournalKey {
      if fault == .journalWriteBefore { fault = nil; throw QueueFixtureError.injected }
      values[key] = data
      if fault == .journalWriteAfter { fault = nil; throw QueueFixtureError.injected }
      return
    }
    if key == pointer, fault == .pointerWriteBefore {
      fault = nil
      throw QueueFixtureError.injected
    }
    values[key] = data
    if key == pointer {
      published = true
      if fault == .pointerWriteAfter { fault = nil; throw QueueFixtureError.injected }
    }
  }
  func remove(_ key: String) throws {
    if key == recoveryJournalKey, journalRemoveFailures > 0 {
      journalRemoveFailures -= 1
      throw QueueFixtureError.injected
    }
    values.removeValue(forKey: key)
  }
}

/// B2e-1 account write queue and durable identity consumption contract. Runs
/// against the same fresh actual Dart golden as the other envelope phases with
/// the standard strict-concurrency flags and compile/run budgets.
@main private struct AccountEnvelopeQueueChecks {
  /// Shared fixture for the queue/identity checks.
  private struct QueueFixture: Sendable {
    let codec: PiliAccountLiveMemoryShadowCodec
    let base: PiliAccountLiveMemoryShadow
    let key: PiliCookieUTF16
    let key2: PiliCookieUTF16
    let record: PiliAccountLiveMemoryRecord
    let generation2: Int64
    let cleared: PiliOrderedCookieArchive
    let fields: [String]
    let location: PiliOrderedCookieResponseLocation
    let now: Int64
    let save: PiliAccountShadowCookieSave
  }

  private static func units(_ text: String) -> PiliCookieUTF16 {
    PiliCookieUTF16(units: Array(text.utf16))
  }

  private static func waitForPending(
    _ store: PiliAccountEnvelopeTransactionStore, _ expected: Int
  ) async throws {
    for _ in 0..<400 {
      if await store.pendingWriteCount == expected { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw QueueFixtureError.failed("write queue did not reach pending \(expected)")
  }

  private static func waitForIdle(
    _ store: PiliAccountEnvelopeTransactionStore
  ) async throws {
    for _ in 0..<400 {
      if await store.writeQueueIdle { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw QueueFixtureError.failed("write queue did not drain to idle")
  }

  private static func waitForManifestReadPaused(_ fault: QueueFaultVault) async throws {
    for _ in 0..<400 {
      if await fault.isManifestReadPaused() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw QueueFixtureError.failed("manifest read pause did not arrive")
  }

  private static func waitForWritePause(_ fault: QueueFaultVault) async throws {
    for _ in 0..<400 {
      if await fault.isWritePaused() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw QueueFixtureError.failed("write pause did not arrive")
  }

  private static func waitForRetrySleep(
    _ store: PiliAccountEnvelopeTransactionStore, _ expected: Int
  ) async throws {
    for _ in 0..<400 {
      if await store.retrySleepCount >= expected { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw QueueFixtureError.failed("queue retry back-off did not start")
  }

  private static func accessText(_ record: PiliAccountLiveMemoryRecord) -> String {
    record.accessKeyUnits.map { String(decoding: $0.units, as: UTF16.self) } ?? "nil"
  }

  /// Receipts carry the durable identity of the exact record they changed, and
  /// `lookupRecord` is a pure read; this is the durable consumer surface Block 3
  /// uses across restarts and renumbering.
  private static func checkIdentityReceipts(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let namespace = UUID()
    let vault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      let adoptReceipt = try await store.adoptMissingIdentities()
      guard let adoptedSnapshot = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing identity snapshot")
      }
      try check(adoptReceipt.adopted == 2 && adoptReceipt.adoptedIdentities.count == 2 &&
        Set(adoptReceipt.adoptedIdentities).count == 2 &&
        adoptReceipt.adoptedIdentities == adoptedSnapshot.envelope.records.dropFirst()
          .compactMap { $0.durableIdentity },
        "adoption receipt carries each minted identity in record order")
      guard let identity1 = adoptedSnapshot.envelope.records[1].durableIdentity,
            let identity2 = adoptedSnapshot.envelope.records[2].durableIdentity else {
        throw QueueFixtureError.failed("adopted identities missing")
      }
      try check(try await store.lookupRecord(durableIdentity: identity1) ==
        adoptedSnapshot.envelope.records[1],
        "identity lookup returns the exact current record")
      try check(try await store.lookupRecord(durableIdentity: units("missing-identity")) == nil,
                "identity lookup misses without a write")
      let afterLookup = try await store.loadShadowSnapshot()
      try check(afterLookup?.transactionID == adoptedSnapshot.transactionID &&
        afterLookup?.envelope == adoptedSnapshot.envelope,
        "identity lookups never move the published pointer")
      let saveReceipt = try await store.applyCookieSave(
        recordKeyUnits: fx.key, expectedGeneration: fx.record.generation, fx.save)
      try check(saveReceipt.durableIdentity == identity1 && saveReceipt.record == 1,
                "transaction receipt carries the target durable identity")
      let installReceipt = try await store.applyInstall(PiliAccountShadowInstall(
        storageKeyUnits: units("identity-new"), mid: 77,
        generation: fx.record.generation + 200,
        accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [.video],
        activated: false, jar: fx.cleared))
      guard let installedIdentity = installReceipt.durableIdentity else {
        throw QueueFixtureError.failed("install identity missing")
      }
      try check(installedIdentity != identity1 && installedIdentity != identity2,
                "install mints a distinct durable identity")
      try check(try await store.lookupRecord(durableIdentity: installedIdentity)?
        .storageKeyUnits == units("identity-new"),
        "installed record is addressable by identity")
      let deleteReceipt = try await store.applyDelete(
        recordKeyUnits: fx.key, expectedGeneration: fx.record.generation)
      try check(deleteReceipt.durableIdentity == identity1,
                "delete receipt names the removed identity")
      guard let afterDelete = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-delete identity snapshot")
      }
      try check(afterDelete.envelope.records[1].storageKeyUnits == fx.key2 &&
        afterDelete.envelope.records[1].durableIdentity == identity2,
        "delete renumbers records but keeps surviving identities")
      try check(try await store.lookupRecord(durableIdentity: identity1) == nil,
                "removed identity is no longer addressable")
      try check(try await store.lookupRecord(durableIdentity: identity2)?.record == 1,
                "surviving identity resolves after renumbering")
      let importReceipt = try await store.applyImport([
        PiliAccountShadowInstall(storageKeyUnits: fx.key2, mid: fx.base.records[2].mid,
          generation: fx.record.generation + 300, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: fx.cleared),
        PiliAccountShadowInstall(storageKeyUnits: units("identity-imported"), mid: 88,
          generation: fx.record.generation + 301, accessKeyUnits: nil, refreshTokenUnits: nil,
          persistedPurposes: [], activated: false, jar: fx.cleared)])
      try check(importReceipt.replaced == 1 && importReceipt.appended == 1 &&
        importReceipt.identities.count == 2,
        "import receipt reports replaced/appended with one identity per input")
      try check(importReceipt.identities[0] == identity2,
                "replacement keeps the existing durable identity")
      try check(importReceipt.identities[1] != identity2 &&
        importReceipt.identities[1] != installedIdentity,
        "append mints a fresh durable identity")
      try check(try await store.lookupRecord(durableIdentity: importReceipt.identities[1])?
        .storageKeyUnits == units("identity-imported"),
        "appended identity is addressable")
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  /// Real-Keychain queued writes: renumbering, replacement generations and a
  /// store restart keep identity addressing and generation validation intact.
  private static func checkQueuedKeychainWrites(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let reducer = PiliNativeOrderedCookieReducer()
    let namespace = UUID()
    let vault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard case .identity(let adoptReceipt) = try await store.enqueue(.adoptIdentities) else {
        throw QueueFixtureError.failed("queued adoption did not return an identity receipt")
      }
      try check(adoptReceipt.adopted == 2 && adoptReceipt.adoptedIdentities.count == 2,
                "queued adoption returns the adopted identities")
      let identity2 = adoptReceipt.adoptedIdentities[1]
      guard case .record(let deleteReceipt) = try await store.enqueue(.delete(
        recordKey: fx.key, generation: fx.record.generation)) else {
        throw QueueFixtureError.failed("queued delete receipt expected")
      }
      try check(deleteReceipt.durableIdentity == adoptReceipt.adoptedIdentities[0],
                "queued delete receipt names the removed identity")
      guard case .record(let saveReceipt) = try await store.enqueue(.cookieSave(
        recordKey: fx.key2, generation: fx.generation2, save: fx.save)) else {
        throw QueueFixtureError.failed("queued save receipt expected")
      }
      try check(saveReceipt.record == 1 && saveReceipt.durableIdentity == identity2,
                "queued save targets the renumbered survivor by key+generation")
      let expectedSecondSave = try reducer.save(fx.base.records[2].jar, fields: fx.fields,
        representation: .separated, location: fx.location, nowMicroseconds: fx.now)
      guard let afterSave = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing queued keychain snapshot")
      }
      try check(afterSave.envelope.records[1].jar == expectedSecondSave,
                "queued save equals the production reducer on the survivor jar")
      try check(try await store.lookupRecord(durableIdentity: identity2)?.record == 1,
                "survivor identity resolves after queued renumbering")
      let replacedGeneration = fx.generation2 + 500
      guard case .importReceipt(let importReceipt) = try await store.enqueue(
        .importRecords([PiliAccountShadowInstall(storageKeyUnits: fx.key2,
          mid: fx.base.records[2].mid, generation: replacedGeneration,
          accessKeyUnits: nil, refreshTokenUnits: nil, persistedPurposes: [],
          activated: false, jar: fx.cleared)])) else {
        throw QueueFixtureError.failed("queued import receipt expected")
      }
      try check(importReceipt.identities == [identity2],
                "queued replacement keeps the durable identity")
      do {
        _ = try await store.enqueue(.cookieDeleteAll(recordKey: fx.key2,
                                                     generation: fx.generation2))
        throw QueueFixtureError.failed("queued stale generation accepted")
      } catch PiliAccountShadowTransactionError.staleGeneration { checks += 1 }
      guard case .record = try await store.enqueue(.cookieDeleteAll(
        recordKey: fx.key2, generation: replacedGeneration)) else {
        throw QueueFixtureError.failed("queued replacement-generation write expected")
      }
      try await waitForIdle(store)
      let restartedVault = PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
      let restartedStore = PiliAccountEnvelopeTransactionStore(vault: restartedVault)
      guard case .record = try await restartedStore.enqueue(.credentials(
        recordKey: fx.key2, generation: replacedGeneration,
        accessKey: units("queue-restart"), refreshToken: nil)) else {
        throw QueueFixtureError.failed("queued restart write expected")
      }
      guard let restarted = try await restartedStore.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing restarted queue snapshot")
      }
      try check(restarted.envelope.records[1].accessKeyUnits?.units ==
        Array("queue-restart".utf16) &&
        restarted.envelope.records[1].durableIdentity == identity2,
        "queue works across a real Keychain restart with a stable identity")
      try check(try await restartedStore.lookupRecord(durableIdentity: identity2)?
        .record == 1,
        "restarted store resolves the identity")
      try await restartedVault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  /// Fault-vault queue semantics: bounded FIFO order, overflow with the
  /// captured activation baseline, queued/in-flight cancellation, queue budget
  /// release, and unknown publications that arm a fail-closed fence resolved
  /// only by a recorded read-back (never replay).
  private static func checkQueuedFifoFaults(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let fault = QueueFaultVault()
    let vault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let store = PiliAccountEnvelopeTransactionStore(
      vault: vault, maxPendingWrites: 2, maxQueueAttempts: 800,
      retryDelayNanoseconds: 5_000_000)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard case .identity(let fifoAdopt) = try await store.enqueue(.adoptIdentities) else {
        throw QueueFixtureError.failed("FIFO adoption identity receipt expected")
      }
      let identity1 = fifoAdopt.adoptedIdentities[0]
      // The actual fresh Dart golden decides the activation baseline; the
      // rejected overflow request attempts its opposite, so a landed overflow
      // would change this exact observable state.
      let baselineActivated = fx.record.activated

      // Same-key FIFO with the first publication paused; overflow rejects.
      await fault.pauseWrite()
      let fifoA = Task { try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("queue-a"), refreshToken: nil)) }
      await fault.waitUntilPaused()
      let fifoB = Task { try await store.enqueue(.cookieDeleteAll(
        recordKey: fx.key, generation: fx.record.generation)) }
      try await waitForPending(store, 1)
      let fifoC = Task { try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("queue-c"), refreshToken: nil)) }
      try await waitForPending(store, 2)
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("queue-overflow"),
          refreshToken: nil))
        throw QueueFixtureError.failed("queue overflow admitted")
      } catch PiliAccountShadowTransactionError.writeQueueOverflow { checks += 1 }
      do {
        _ = try await store.enqueue(.activated(recordKey: fx.key,
          generation: fx.record.generation, activated: !baselineActivated))
        throw QueueFixtureError.failed("queue overflow activation admitted")
      } catch PiliAccountShadowTransactionError.writeQueueOverflow { checks += 1 }
      await fault.resume()
      let outcomeA = try await fifoA.value
      let outcomeB = try await fifoB.value
      let outcomeC = try await fifoC.value
      guard case .record(let receiptA) = outcomeA,
            case .record(let receiptB) = outcomeB,
            case .record(let receiptC) = outcomeC else {
        throw QueueFixtureError.failed("FIFO outcomes are not record receipts")
      }
      try check(receiptA.transactionID != receiptB.transactionID &&
        receiptB.transactionID != receiptC.transactionID,
        "queued publications keep distinct pointer identities")
      try await waitForIdle(store)
      // Every receipt must name the exact immutable candidate it published.
      let candidateA = try await vault.loadPublishedCandidate(transactionID: receiptA.transactionID)
      let candidateB = try await vault.loadPublishedCandidate(transactionID: receiptB.transactionID)
      let candidateC = try await vault.loadPublishedCandidate(transactionID: receiptC.transactionID)
      try check(accessText(candidateA.records[1]) == "queue-a",
                "receipt A names the candidate carrying its own credentials")
      try check(candidateB.records[1].jar == fx.cleared &&
        accessText(candidateB.records[1]) == "queue-a",
        "receipt B names the candidate that applied deleteAll on A")
      try check(accessText(candidateC.records[1]) == "queue-c" &&
        candidateC.records[1].jar == fx.cleared,
        "receipt C names the candidate that built on B")
      guard let reloaded = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing FIFO snapshot")
      }
      try check(reloaded.transactionID == receiptC.transactionID,
                "the rejected overflow writes publish nothing after C")
      try check(reloaded.envelope.records[1].accessKeyUnits?.units == Array("queue-c".utf16),
                "final queued credentials keep submission order")
      try check(reloaded.envelope.records[1].jar == fx.cleared,
                "final queued deleteAll survives the later credentials write")
      try check(reloaded.envelope.records[1].activated == baselineActivated,
                "the rejected overflow activation keeps the actual captured baseline")
      let pendingAfterDrain = await store.pendingWriteCount
      let idleAfterDrain = await store.writeQueueIdle
      try check(pendingAfterDrain == 0 && idleAfterDrain,
                "the FIFO releases every turn after draining")
      let publishedRecords = await fault.recordCount()
      try check(publishedRecords == 5,
                "the queue publishes exactly one record per admitted write")

      // Cancellation while queued: the cancelled waiter must publish nothing
      // even though a valid follower runs afterwards, so the cancelled write
      // uses a discriminating jar effect that the follower never overwrites,
      // and the exact publication count proves only holder + follower landed.
      let preCancelRecords = await fault.recordCount()
      await fault.pauseWrite()
      let holder = Task { try await store.enqueue(.cookieDeleteAll(
        recordKey: fx.key, generation: fx.record.generation)) }
      await fault.waitUntilPaused()
      let cancelled = Task { try await store.enqueue(.cookieSave(
        recordKey: fx.key, generation: fx.record.generation, save: fx.save)) }
      try await waitForPending(store, 1)
      let follower = Task { try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("queue-follower"),
        refreshToken: nil)) }
      try await waitForPending(store, 2)
      cancelled.cancel()
      await fault.resume()
      _ = try await holder.value
      var queuedCancelled = false
      do {
        _ = try await cancelled.value
      } catch is CancellationError { queuedCancelled = true }
      try check(queuedCancelled,
                "a queued write cancelled before its turn publishes nothing")
      guard case .record = try await follower.value else {
        throw QueueFixtureError.failed("follower after queued cancellation expected")
      }
      try await waitForIdle(store)
      let afterCancel = try await store.loadShadowSnapshot()
      try check(afterCancel?.envelope.records[1].accessKeyUnits?.units ==
        Array("queue-follower".utf16),
        "the valid follower after the cancelled waiter still lands")
      try check(afterCancel?.envelope.records[1].jar == fx.cleared,
        "the cancelled queued cookieSave never lands (jar stays cleared)")
      try check(await fault.recordCount() == preCancelRecords + 2,
        "exactly holder + follower were published across the cancellation")

      // In-flight cancellation before the pointer write keeps the previous jar
      // and publishes no record at all.
      let preInFlightRecords = await fault.recordCount()
      await fault.pauseWrite()
      let inFlight = Task { try await store.enqueue(.cookieSave(
        recordKey: fx.key, generation: fx.record.generation, save: fx.save)) }
      await fault.waitUntilPaused()
      inFlight.cancel()
      await fault.resume()
      var inFlightCancelled = false
      do {
        _ = try await inFlight.value
      } catch is CancellationError { inFlightCancelled = true }
      try check(inFlightCancelled,
                "an in-flight queued publication cancelled before the pointer reports cancellation")
      try await waitForIdle(store)
      let afterInFlight = try await store.loadShadowSnapshot()
      try check(afterInFlight?.envelope.records[1].jar == fx.cleared,
                "cancelled in-flight publication leaves the durable jar unchanged")
      try check(await fault.recordCount() == preInFlightRecords,
                "cancelled in-flight publication adds no record")

      // A queued resource-budget rejection releases the turn with no
      // publication and no fabricated receipt; a valid follower continues.
      guard let beforeBudget = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing pre-budget snapshot")
      }
      let preBudgetRecords = await fault.recordCount()
      try check(preBudgetRecords == preInFlightRecords,
                "the pinned pre-budget count equals the post-cancellation contract")
      do {
        _ = try await store.enqueue(.buvidSeed(recordKey: fx.key,
          generation: fx.record.generation,
          value: PiliCookieUTF16(units: Array(repeating: 0x41,
            count: PiliAccountEnvelopeTransactionStore.buvidMaximumValueUnits + 1)),
          nowMicroseconds: fx.now))
        throw QueueFixtureError.failed("queued over-budget buvid accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
      try check(await fault.recordCount() == preBudgetRecords,
                "the rejected queued budget write adds no record")
      guard let afterBudget = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-budget snapshot")
      }
      try check(afterBudget.transactionID == beforeBudget.transactionID &&
        afterBudget.envelope == beforeBudget.envelope,
        "a rejected queued budget write publishes nothing")
      guard case .record(let budgetFollower) = try await store.enqueue(.credentials(
        recordKey: fx.key, generation: fx.record.generation,
        accessKey: units("queue-after-budget"), refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after queued budget rejection expected")
      }
      try check(budgetFollower.durableIdentity == identity1 && budgetFollower.record == 1,
                "the follower after the budget rejection carries the target identity")
      guard let afterBudgetFollower = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-budget follower snapshot")
      }
      try check(afterBudgetFollower.envelope.records[1].accessKeyUnits?.units ==
        Array("queue-after-budget".utf16),
        "the queue keeps draining after a resource-budget rejection")
      try check(await fault.recordCount() == preBudgetRecords + 1,
                "the budget rejection adds no record beyond its follower")

      // Unknown install: A is admitted and paused before B exists, so the
      // armed pointer-read fault is consumed by the intended operation. The
      // unknown arms a fail-closed fence: the same-key follower must not
      // publish until a recorded read-back resolution.
      await fault.arm(.pointerReadAfter)
      await fault.pauseWrite()
      let unknownInstall = PiliAccountShadowInstall(storageKeyUnits: units("queue-unknown"),
        mid: 99, generation: fx.record.generation + 900, accessKeyUnits: nil,
        refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: fx.cleared)
      let unknownA = Task { try await store.enqueue(.install(unknownInstall)) }
      try await waitForWritePause(fault)
      let unknownB = Task { try await store.enqueue(.cookieSave(
        recordKey: fx.key, generation: fx.record.generation, save: fx.save)) }
      try await waitForPending(store, 1)
      await fault.resume()
      var unknownSurfaced = false
      do {
        _ = try await unknownA.value
        throw QueueFixtureError.failed("unknown publication fabricated a receipt")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { unknownSurfaced = true }
      try check(unknownSurfaced,
                "queued unknown publication propagates instead of a fake receipt")
      try await waitForIdle(store)
      guard let unresolved = await store.pendingUnresolvedPublication else {
        throw QueueFixtureError.failed("unknown publication left no fence")
      }
      try check(unresolved.kind == .install && unresolved.attemptedCandidateSHA256.count == 64,
                "the fence keeps the exact attempted-candidate evidence")
      var followerFenced = false
      do {
        _ = try await unknownB.value
        throw QueueFixtureError.failed("follower published during an unresolved publication")
      } catch PiliAccountShadowTransactionError.unresolvedPublication { followerFenced = true }
      try check(followerFenced,
                "a same-key overwriting follower fails closed until resolution")
      guard let unknownReadback = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing unknown read-back snapshot")
      }
      guard let unknownResolution = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("unknown publication had no resolution")
      }
      try check(unknownResolution.outcome == .attemptCommitted &&
        unknownResolution.observedTransactionID == unknownResolution.attemptedTransactionID &&
        unknownResolution.observedTransactionID == unknownReadback.transactionID &&
        unknownResolution.attemptedCandidateSHA256 == unresolved.attemptedCandidateSHA256,
        "read-back resolution correlates the exact attempted operation identity")
      try check(await store.pendingUnresolvedPublication == nil,
                "the recorded read-back releases the fence")
      guard case .record(let recoveredB) = try await store.enqueue(.cookieSave(
        recordKey: fx.key, generation: fx.record.generation, save: fx.save)) else {
        throw QueueFixtureError.failed("follower after resolution expected")
      }
      try check(recoveredB.durableIdentity == identity1,
                "the released follower carries the target identity")
      guard let afterUnknown = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-unknown snapshot")
      }
      try check(afterUnknown.envelope.records.count == 4 &&
        afterUnknown.envelope.records[3].storageKeyUnits == units("queue-unknown") &&
        afterUnknown.envelope.records[1].jar != fx.cleared,
        "the unknown publication is durable once and the follower ran after resolution")
      do {
        _ = try await store.enqueue(.install(unknownInstall))
        throw QueueFixtureError.failed("unknown install replay accepted")
      } catch PiliAccountShadowTransactionError.duplicateRecordKey { checks += 1 }

      // Unknown buvid with the fence: read-back resolves the durable seed; the
      // correct next step is an explicit idempotent no-op, never a blind replay.
      await fault.arm(.pointerReadAfter)
      let buvidUnknown = Task { try await store.enqueue(.buvidSeed(recordKey: fx.key,
        generation: fx.record.generation, value: units("queue-buvid"),
        nowMicroseconds: fx.now)) }
      var buvidUnknownSurfaced = false
      do {
        _ = try await buvidUnknown.value
        throw QueueFixtureError.failed("unknown buvid fabricated a receipt")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { buvidUnknownSurfaced = true }
      try check(buvidUnknownSurfaced, "unknown buvid publication is never a fake success")
      guard let buvidResolution = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("unknown buvid left no resolution")
      }
      try check(buvidResolution.outcome == .attemptCommitted,
                "the unknown buvid is resolved by exact operation identity")
      guard let buvidReadback = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing buvid read-back snapshot")
      }
      let buvidDomain = units("bilibili.com")
      let buvidPath = units("/")
      let buvidName = units("buvid3")
      let buvidPresent = buvidReadback.envelope.records[1].jar.domainBuckets
        .first { $0.keyUnits == buvidDomain }?
        .paths.first { $0.keyUnits == buvidPath }?
        .cookies.contains { $0.keyUnits == buvidName } ?? false
      guard case .buvid(let buvidRetry) = try await store.enqueue(.buvidSeed(
        recordKey: fx.key, generation: fx.record.generation,
        value: units("queue-buvid"), nowMicroseconds: fx.now + 1)) else {
        throw QueueFixtureError.failed("buvid retry outcome expected")
      }
      try check(buvidPresent && !buvidRetry.seeded && buvidRetry.transactionID == nil &&
        buvidRetry.durableIdentity == identity1,
        "read-back resolves the unknown buvid and the retry is a durable no-op")
      try await waitForIdle(store)
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  /// Cross-store contention on one shared vault actor (fence retry) and a
  /// genuine CAS staleTransaction interleaved by a second vault instance.
  private static func checkQueueContention(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }

    let fenceFault = QueueFaultVault()
    let fenceVault = PiliAccountEnvelopeStagingStore(secrets: fenceFault)
    let storeA = PiliAccountEnvelopeTransactionStore(
      vault: fenceVault, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    let storeB = PiliAccountEnvelopeTransactionStore(
      vault: fenceVault, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    do {
      try await fenceVault.importShadow(fx.codec.encode(fx.base))
      _ = try await storeA.enqueue(.adoptIdentities)
      await fenceFault.pauseWrite()
      let writeA = Task { try await storeA.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("store-a"), refreshToken: nil)) }
      await fenceFault.waitUntilPaused()
      let writeB = Task { try await storeB.enqueue(.cookieDeleteAll(
        recordKey: fx.key2, generation: fx.generation2)) }
      // R26: storeB is a genuinely cold store. Its recovery preflight reads the
      // shared vault under the same operation fence as storeA's paused write,
      // so it must show bounded retry evidence before storeA resumes instead
      // of leaking operationInProgress out of enqueue.
      try await waitForRetrySleep(storeB, 1)
      await fenceFault.resume()
      guard case .record = try await writeA.value else {
        throw QueueFixtureError.failed("storeA contention write expected a record receipt")
      }
      guard case .record = try await writeB.value else {
        throw QueueFixtureError.failed("cold storeB contention write expected a record receipt")
      }
      try await waitForIdle(storeA)
      try await waitForIdle(storeB)
      let reloaded = try await PiliAccountEnvelopeStagingStore(secrets: fenceFault).loadShadow()
      try check(reloaded?.records[1].accessKeyUnits?.units == Array("store-a".utf16) &&
        reloaded?.records[2].jar == fx.cleared,
        "cross-store queued writes serialize through the shared vault without lost updates")
      try check(await fenceFault.recordCount() == 4,
        "the cold contention preflight publishes exactly one record per admitted write")
      try await fenceVault.discardShadow()
    } catch {
      try? await fenceVault.discardShadow()
      throw error
    }

    let casFault = QueueFaultVault()
    let vault1 = PiliAccountEnvelopeStagingStore(secrets: casFault)
    let vault2 = PiliAccountEnvelopeStagingStore(secrets: casFault)
    let queuedStore = PiliAccountEnvelopeTransactionStore(
      vault: vault1, maxQueueAttempts: 200, retryDelayNanoseconds: 5_000_000)
    let interveningStore = PiliAccountEnvelopeTransactionStore(vault: vault2)
    do {
      try await vault1.importShadow(fx.codec.encode(fx.base))
      _ = try await queuedStore.enqueue(.adoptIdentities)
      await casFault.pauseManifestReadAfter(1)
      let queued = Task { try await queuedStore.enqueue(.cookieDeleteAll(
        recordKey: fx.key, generation: fx.record.generation)) }
      await casFault.waitUntilManifestReadPaused()
      _ = try await interveningStore.applyCredentials(recordKeyUnits: fx.key,
        expectedGeneration: fx.record.generation, accessKeyUnits: units("intervening"),
        refreshTokenUnits: nil)
      await casFault.resumeManifestRead()
      let queuedOutcome = try await queued.value
      guard case .record(let queuedReceipt) = queuedOutcome else {
        throw QueueFixtureError.failed("CAS-retried outcome is not a record receipt")
      }
      try await waitForIdle(queuedStore)
      let final = try await PiliAccountEnvelopeStagingStore(secrets: casFault).loadShadow()
      try check(final?.records[1].jar == fx.cleared &&
        final?.records[1].accessKeyUnits?.units == Array("intervening".utf16),
        "a stale queued publish is retried and preserves the intervening publication")
      let queuedCandidate = try await vault1.loadPublishedCandidate(
        transactionID: queuedReceipt.transactionID)
      try check(queuedCandidate.records[1].accessKeyUnits?.units ==
        Array("intervening".utf16) && queuedCandidate.records[1].jar == fx.cleared,
        "the retried queued transform re-read the fresh snapshot")
      try await vault1.discardShadow()
    } catch {
      try? await vault1.discardShadow()
      throw error
    }
    return checks
  }

  /// R26: a cold recovery preflight against a legitimately busy shared vault
  /// is retried inside the same bounded store budget with typed exhaustion,
  /// while unknown/corrupt journal states stay fail-closed and are never
  /// retried into a clean namespace.
  private static func checkColdRecoveryContention(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }

    // Concurrent same-store first use: two cold enqueues on one fresh store
    // while a third shared-vault publisher is paused. Both must retry, then
    // succeed with both effects and exactly one publication each.
    let fault1 = QueueFaultVault()
    let vault1 = PiliAccountEnvelopeStagingStore(secrets: fault1)
    let holder1 = PiliAccountEnvelopeTransactionStore(
      vault: vault1, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    let cold1 = PiliAccountEnvelopeTransactionStore(
      vault: vault1, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    do {
      try await vault1.importShadow(fx.codec.encode(fx.base))
      await fault1.pauseWrite()
      let holderWrite = Task { try await holder1.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("cold-holder"), refreshToken: nil)) }
      await fault1.waitUntilPaused()
      let coldA = Task { try await cold1.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("cold-a"), refreshToken: nil)) }
      let coldB = Task { try await cold1.enqueue(.cookieDeleteAll(
        recordKey: fx.key2, generation: fx.generation2)) }
      try await waitForRetrySleep(cold1, 1)
      await fault1.resume()
      guard case .record = try await holderWrite.value else {
        throw QueueFixtureError.failed("cold-holder write expected a record receipt")
      }
      guard case .record = try await coldA.value, case .record = try await coldB.value else {
        throw QueueFixtureError.failed("concurrent cold first-use writes expected record receipts")
      }
      try await waitForIdle(cold1)
      guard let snapshot1 = try await cold1.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing concurrent cold first-use snapshot")
      }
      try check(snapshot1.envelope.records[1].accessKeyUnits?.units == Array("cold-a".utf16) &&
        snapshot1.envelope.records[2].jar == fx.cleared,
        "concurrent cold first use keeps both effects under shared-vault contention")
      try check(await fault1.recordCount() == 4,
        "concurrent cold first use publishes exactly one record per admitted write")
      try await vault1.discardShadow()
    } catch {
      try? await vault1.discardShadow()
      throw error
    }

    // Bounded exhaustion: a cold store with a tiny shared budget fails the
    // preflight with the typed publicationConflict (never a raw
    // operationInProgress), publishes nothing, and a follower on the same
    // store succeeds once the contention clears.
    let fault2 = QueueFaultVault()
    let vault2 = PiliAccountEnvelopeStagingStore(secrets: fault2)
    let holder2 = PiliAccountEnvelopeTransactionStore(
      vault: vault2, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    let bound2 = PiliAccountEnvelopeTransactionStore(
      vault: vault2, maxQueueAttempts: 3, retryDelayNanoseconds: 1_000_000)
    do {
      try await vault2.importShadow(fx.codec.encode(fx.base))
      await fault2.pauseWrite()
      let holderWrite2 = Task { try await holder2.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("bound-holder"), refreshToken: nil)) }
      await fault2.waitUntilPaused()
      var bounded = false
      do {
        _ = try await bound2.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-bypass-budget"),
          refreshToken: nil))
        throw QueueFixtureError.failed("exhausted cold recovery preflight admitted a write")
      } catch PiliAccountShadowTransactionError.publicationConflict { bounded = true }
      try check(bounded,
        "an exhausted cold recovery preflight fails closed with the typed bounded error")
      try check(await bound2.retrySleepCount == 2,
        "the cold recovery preflight consumes exactly the shared bounded attempts")
      try check(await fault2.recordCount() == 1,
        "the exhausted cold recovery preflight publishes nothing")
      try check(await bound2.pendingUnresolvedPublication == nil,
        "the exhausted cold recovery preflight leaves no fence")
      await fault2.resume()
      guard case .record = try await holderWrite2.value else {
        throw QueueFixtureError.failed("bound-holder write expected a record receipt")
      }
      guard case .record = try await bound2.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("cold-after-bound"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after cold preflight exhaustion expected")
      }
      try await waitForIdle(bound2)
      guard let snapshot2 = try await bound2.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-exhaustion follower snapshot")
      }
      try check(snapshot2.envelope.records[1].accessKeyUnits?.units ==
        Array("cold-after-bound".utf16),
        "the follower after cold preflight exhaustion loads and publishes normally")
      try check(await fault2.recordCount() == 3,
        "the follower after cold preflight exhaustion publishes exactly once")
      try await vault2.discardShadow()
    } catch {
      try? await vault2.discardShadow()
      throw error
    }

    // Cancellation while the cold preflight waits: nothing is admitted or
    // published, the store stays idle, and a later write loads and succeeds.
    let fault3 = QueueFaultVault()
    let vault3 = PiliAccountEnvelopeStagingStore(secrets: fault3)
    let holder3 = PiliAccountEnvelopeTransactionStore(
      vault: vault3, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    let cancelled3 = PiliAccountEnvelopeTransactionStore(
      vault: vault3, maxQueueAttempts: 800, retryDelayNanoseconds: 20_000_000)
    do {
      try await vault3.importShadow(fx.codec.encode(fx.base))
      await fault3.pauseWrite()
      let holderWrite3 = Task { try await holder3.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("cancel-holder"), refreshToken: nil)) }
      await fault3.waitUntilPaused()
      let cancelledWrite = Task { try await cancelled3.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("must-not-publish-cancelled"),
        refreshToken: nil)) }
      try await waitForRetrySleep(cancelled3, 1)
      cancelledWrite.cancel()
      var coldCancelled = false
      do {
        _ = try await cancelledWrite.value
      } catch is CancellationError { coldCancelled = true }
      try check(coldCancelled,
        "a cancelled cold recovery preflight resolves nothing")
      try check(await fault3.recordCount() == 1,
        "a cancelled cold recovery preflight publishes nothing")
      let idleAfterCancel = await cancelled3.writeQueueIdle
      try check(await cancelled3.pendingWriteCount == 0 && idleAfterCancel,
        "a cancelled cold recovery preflight never occupies the FIFO")
      await fault3.resume()
      guard case .record = try await holderWrite3.value else {
        throw QueueFixtureError.failed("cancel-holder write expected a record receipt")
      }
      guard case .record = try await cancelled3.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-cold-cancel"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("write after cold preflight cancellation expected")
      }
      try await waitForIdle(cancelled3)
      guard let snapshot3 = try await cancelled3.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-cancellation snapshot")
      }
      try check(snapshot3.envelope.records[1].accessKeyUnits?.units ==
        Array("after-cold-cancel".utf16),
        "the store loads and publishes after a cancelled cold preflight")
      try check(await fault3.recordCount() == 3,
        "the write after cold preflight cancellation publishes exactly once")
      try await vault3.discardShadow()
    } catch {
      try? await vault3.discardShadow()
      throw error
    }

    // Pending journal on a cold reopen with contention: the preflight retries
    // the definite shared-vault contention, then arms the exact persisted
    // fence; the journal survives and the ambiguous pointer is released only
    // by the explicit acknowledgment without replay.
    let fault4 = QueueFaultVault()
    let vault4 = PiliAccountEnvelopeStagingStore(secrets: fault4)
    do {
      try await vault4.importShadow(fx.codec.encode(fx.base))
      guard let baseline4 = try await vault4.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("cold pending-journal baseline missing")
      }
      let pendingAttempt4 = UUID()
      try await fault4.write(
        try PiliAccountEnvelopeRecoveryJournal.encode(PiliAccountEnvelopeRecoveryJournal(
          attemptedTransactionID: pendingAttempt4,
          expectedPreviousTransactionID: baseline4.transactionID,
          attemptedCandidateSHA256: String(repeating: "e", count: 64),
          kind: "credentials")),
        key: PiliAccountEnvelopeRecoveryJournal.journalKey)
      await fault4.pauseWrite()
      let rawHolder4 = Task { try await vault4.importShadow(fx.codec.encode(fx.base)) }
      await fault4.waitUntilPaused()
      let reopenedVault4 = PiliAccountEnvelopeStagingStore(secrets: fault4)
      let reopened4 = PiliAccountEnvelopeTransactionStore(
        vault: reopenedVault4, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
      let reopenedWrite4 = Task { try await reopened4.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("must-not-cross-reopened"),
        refreshToken: nil)) }
      try await waitForRetrySleep(reopened4, 1)
      await fault4.resume()
      _ = try await rawHolder4.value
      var fencedAfterContention = false
      do {
        _ = try await reopenedWrite4.value
      } catch PiliAccountShadowTransactionError.unresolvedPublication {
        fencedAfterContention = true
      }
      try check(fencedAfterContention,
        "a reopened pending journal still fences after cold-preflight contention")
      guard try await reopenedVault4.loadRecoveryJournal() != nil else {
        throw QueueFixtureError.failed("the reopened pending journal was lost during contention")
      }
      var blocked4 = false
      do {
        _ = try await reopened4.resolveUnresolvedPublication()
      } catch PiliAccountShadowTransactionError.ambiguousRecovery { blocked4 = true }
      try check(blocked4,
        "the reopened ambiguous journal keeps its evidence until acknowledged")
      guard let acknowledged4 = try await reopened4.resolveUnresolvedPublication(
        allowAmbiguous: true) else {
        throw QueueFixtureError.failed("reopened pending journal left no acknowledged resolution")
      }
      try check(acknowledged4.outcome == .ambiguousObservedCandidate &&
        acknowledged4.attemptedTransactionID == pendingAttempt4,
        "the reopened journal resolves only as an explicit acknowledged ambiguity")
      guard try await reopenedVault4.loadRecoveryJournal() == nil else {
        throw QueueFixtureError.failed("the acknowledged reopened journal was not cleared")
      }
      guard case .record = try await reopened4.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-reopened-fence"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after acknowledged reopened fence expected")
      }
      try await waitForIdle(reopened4)
      try check(await fault4.recordCount() == 3,
        "the acknowledged reopened journal publishes exactly the follower")
      try await vault4.discardShadow()
    } catch {
      try? await vault4.discardShadow()
      throw error
    }

    // Corrupt journal on a cold reopen with contention: after the definite
    // contention clears, the strict decode fails closed; the preflight never
    // retries a corrupt artifact into a clean namespace and publishes nothing.
    let fault5 = QueueFaultVault()
    let vault5 = PiliAccountEnvelopeStagingStore(secrets: fault5)
    do {
      try await vault5.importShadow(fx.codec.encode(fx.base))
      try await fault5.write(Data("{\"not\":\"a journal\"}".utf8),
        key: PiliAccountEnvelopeRecoveryJournal.journalKey)
      await fault5.pauseWrite()
      let rawHolder5 = Task { try await vault5.importShadow(fx.codec.encode(fx.base)) }
      await fault5.waitUntilPaused()
      let corruptStore5 = PiliAccountEnvelopeTransactionStore(
        vault: PiliAccountEnvelopeStagingStore(secrets: fault5),
        maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
      let corruptWrite5 = Task { try await corruptStore5.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("must-not-publish-corrupt"),
        refreshToken: nil)) }
      try await waitForRetrySleep(corruptStore5, 1)
      await fault5.resume()
      _ = try await rawHolder5.value
      var corruptSurfaced = false
      do {
        _ = try await corruptWrite5.value
        throw QueueFixtureError.failed("corrupt journal preflight fabricated success")
      } catch PiliAccountEnvelopeStagingError.invalidRecoveryJournal { corruptSurfaced = true }
      try check(corruptSurfaced,
        "a corrupt journal fails closed after cold-preflight contention")
      try check(await fault5.recordCount() == 2,
        "the corrupt journal preflight publishes nothing")
      guard try await fault5.read(PiliAccountEnvelopeRecoveryJournal.journalKey) != nil else {
        throw QueueFixtureError.failed("the corrupt journal was deleted during contention")
      }
      try await fault5.remove(PiliAccountEnvelopeRecoveryJournal.journalKey)
      try await vault5.discardShadow()
    } catch {
      try? await vault5.discardShadow()
      throw error
    }
    return checks
  }

  /// Queued purpose/temporarySelection/activated/buvid receipts must carry the
  /// exact target durable identity, keep both gates false, and their candidate
  /// state must be exactly as promised (activation uses the opposite of the
  /// actual captured baseline; buvid clears the jar first so the seed path is
  /// genuinely exercised, never an idempotent no-op).
  private static func checkQueuedEffectReceipts(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let namespace = UUID()
    let vault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard case .identity(let adopt) = try await store.enqueue(.adoptIdentities) else {
        throw QueueFixtureError.failed("identity adoption for effect receipts expected")
      }
      let identity2 = adopt.adoptedIdentities[1]
      let record2 = fx.base.records[2].record

      guard case .record(let tempReceipt) = try await store.enqueue(.temporarySelection(
        recordKey: fx.key2, generation: fx.generation2, purpose: .main)) else {
        throw QueueFixtureError.failed("queued temporary selection receipt expected")
      }
      try check(tempReceipt.durableIdentity == identity2 && tempReceipt.record == record2 &&
        !tempReceipt.nativeWritesAllowed && !tempReceipt.authoritySwitchAllowed,
        "the temporary-selection receipt carries the selected identity and closed gates")
      guard let afterTemp = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing temporary-selection snapshot")
      }
      let heartbeat = afterTemp.envelope.selections[1]
      let expectedHistory = afterTemp.envelope.records[heartbeat].isLogin
        ? heartbeat : afterTemp.envelope.selections[0]
      try check(afterTemp.envelope.selections[0] == record2 &&
        afterTemp.envelope.history == expectedHistory,
        "the temporary selection points the slot and derives history exactly")

      let baselineActivated = fx.base.records[2].activated
      guard case .record(let activationReceipt) = try await store.enqueue(.activated(
        recordKey: fx.key2, generation: fx.generation2, activated: !baselineActivated)) else {
        throw QueueFixtureError.failed("queued activation receipt expected")
      }
      try check(activationReceipt.durableIdentity == identity2 &&
        activationReceipt.record == record2,
        "the activation receipt carries the target identity")
      guard let afterActivation = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing activation snapshot")
      }
      try check(afterActivation.envelope.records[2].activated == !baselineActivated,
                "the activation write applies the requested opposite of the baseline")

      guard case .record = try await store.enqueue(.cookieDeleteAll(
        recordKey: fx.key2, generation: fx.generation2)) else {
        throw QueueFixtureError.failed("queued clear before the buvid seed expected")
      }
      guard case .buvid(let buvidReceipt) = try await store.enqueue(.buvidSeed(
        recordKey: fx.key2, generation: fx.generation2,
        value: units("queue-effect-buvid"), nowMicroseconds: fx.now)) else {
        throw QueueFixtureError.failed("queued buvid receipt expected")
      }
      try check(buvidReceipt.seeded && buvidReceipt.transactionID != nil &&
        buvidReceipt.durableIdentity == identity2 &&
        !buvidReceipt.nativeWritesAllowed && !buvidReceipt.authoritySwitchAllowed,
        "the buvid receipt carries the seeded identity and closed gates")
      guard let afterBuvid = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing buvid snapshot")
      }
      let domain = units("bilibili.com")
      let path = units("/")
      let name = units("buvid3")
      let present = afterBuvid.envelope.records[2].jar.domainBuckets
        .first { $0.keyUnits == domain }?
        .paths.first { $0.keyUnits == path }?
        .cookies.contains { $0.keyUnits == name } ?? false
      try check(present, "the seeded buvid is durable in the bilibili.com root path")
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  /// Direct-API unknown protocol on a fault vault: write-before-error and
  /// write-after-error plus unreadable acknowledgment, a persistent read-back
  /// failure that keeps the fence, fail-closed followers, explicit recovery,
  /// and the reopen boundary. The attempted-candidate identity is the
  /// correlation evidence; nothing infers success from a matching payload and
  /// nothing replays the unknown write.
  private static func checkUnknownFenceProtocol(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let fault = QueueFaultVault()
    let vault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard case .identity(let adopt) = try await store.enqueue(.adoptIdentities) else {
        throw QueueFixtureError.failed("identity adoption for the unknown protocol expected")
      }
      let identity1 = adopt.adoptedIdentities[0]
      guard let beforeUnknown = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing pre-unknown snapshot")
      }

      // Write-before-error + unreadable acknowledgment: nothing can have been
      // published, and resolution must not claim the attempt landed.
      await fault.arm(.pointerWriteBefore)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.applyCredentials(recordKeyUnits: fx.key,
          expectedGeneration: fx.record.generation, accessKeyUnits: units("unknown-before"),
          refreshTokenUnits: nil)
        throw QueueFixtureError.failed("write-before-error fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let beforeUnresolved = await store.pendingUnresolvedPublication else {
        throw QueueFixtureError.failed("write-before-error left no fence")
      }
      try check(beforeUnresolved.kind == .credentials &&
        beforeUnresolved.expectedPreviousTransactionID == beforeUnknown.transactionID,
        "the fence records the exact expected previous pointer")
      // Persistent read-back failure keeps the fence and blocks every write.
      await fault.failPointerReadsForever()
      var readbackFailed = false
      do {
        _ = try await store.resolveUnresolvedPublication()
      } catch { readbackFailed = true }
      let fenceStillHeld: PiliAccountShadowUnresolvedPublication? =
        await store.pendingUnresolvedPublication
      try check(readbackFailed && fenceStillHeld != nil,
                "a failed read-back keeps the fence armed")
      var fencedWrite = false
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-publish"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { fencedWrite = true }
      try check(fencedWrite, "durable writes fail closed while the fence is armed")
      await fault.allowPointerReads()
      guard let beforeResolution = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("write-before-error fence did not resolve")
      }
      try check(beforeResolution.outcome == .attemptNotCommitted &&
        beforeResolution.observedTransactionID == beforeUnknown.transactionID,
        "the write-before-error resolution proves the pointer never moved")
      guard case .record(let explicitRetry) = try await store.enqueue(.credentials(
        recordKey: fx.key, generation: fx.record.generation,
        accessKey: units("unknown-before"), refreshToken: nil)) else {
        throw QueueFixtureError.failed("explicit retry after resolution expected")
      }
      try check(explicitRetry.durableIdentity == identity1,
                "the caller's explicit retry after read-back carries the target identity")
      guard let afterRetry = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing retry snapshot")
      }
      try check(afterRetry.envelope.records[1].accessKeyUnits?.units ==
        Array("unknown-before".utf16),
        "only the explicit post-resolution retry lands the write")

      // Write-after-error + unreadable acknowledgment: the pointer write
      // committed before the failure; resolution must prove that exact
      // candidate is published without replaying and without a fake receipt.
      await fault.arm(.pointerWriteAfter)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("unknown-after"),
          refreshToken: nil))
        throw QueueFixtureError.failed("write-after-error fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard await store.pendingUnresolvedPublication != nil else {
        throw QueueFixtureError.failed("write-after-error left no fence")
      }
      try await waitForIdle(store)
      var followerFenced = false
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-overwrite"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { followerFenced = true }
      try check(followerFenced, "a same-key follower cannot erase the unknown evidence")
      guard let afterResolution = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("write-after-error fence did not resolve")
      }
      try check(afterResolution.outcome == .attemptCommitted &&
        afterResolution.observedTransactionID == afterResolution.attemptedTransactionID &&
        afterResolution.observedTransactionID != afterRetry.transactionID,
        "the write-after-error resolution names the committed attempted operation")
      guard let durableAfter = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-resolution snapshot")
      }
      try check(durableAfter.envelope.records[1].accessKeyUnits?.units ==
        Array("unknown-after".utf16),
        "the committed unknown write is durable exactly once, without replay")

      // Reopen boundary: the durable journal makes a recreated store arm its
      // fence from persisted evidence before it may admit any follower.
      await fault.arm(.pointerReadAfter)
      let reopenUnknown = Task { try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("unknown-reopen"),
        refreshToken: nil)) }
      var reopenSurfaced = false
      do {
        _ = try await reopenUnknown.value
        throw QueueFixtureError.failed("reopen unknown fabricated a receipt")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { reopenSurfaced = true }
      try check(reopenSurfaced, "the reopen-boundary unknown propagates")
      var oldStoreFenced = false
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("old-store-must-not-publish"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { oldStoreFenced = true }
      try check(oldStoreFenced, "the original store stays fenced after the unknown")
      let restartedVault = PiliAccountEnvelopeStagingStore(secrets: fault)
      let restartedStore = PiliAccountEnvelopeTransactionStore(vault: restartedVault)
      guard let restartedRecovery = try await restartedStore.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("restarted store lost the unresolved evidence")
      }
      try check(restartedRecovery.kind == .credentials &&
        restartedRecovery.attemptedCandidateSHA256.count == 64,
        "a recreated store arms the fence from the durable journal")
      var restartedFenced = false
      do {
        _ = try await restartedStore.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-cross-reopen"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { restartedFenced = true }
      try check(restartedFenced,
                "a recreated store never admits an overwriting follower from empty memory")
      guard let restartedResolution = try await restartedStore.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("restarted recovery did not resolve")
      }
      try check(restartedResolution.outcome == .attemptCommitted,
                "the recreated store resolves the committed unknown by operation identity")
      guard let restartedReadback = try await restartedStore.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing restarted read-back")
      }
      try check(restartedReadback.envelope.records[1].accessKeyUnits?.units ==
        Array("unknown-reopen".utf16),
        "a fresh store reads the committed unknown candidate before writing")
      guard case .record = try await restartedStore.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("reopen-follower"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("restarted follower expected")
      }
      guard let reopenFinal = try await restartedStore.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing reopen final snapshot")
      }
      try check(reopenFinal.envelope.records[1].accessKeyUnits?.units ==
        Array("reopen-follower".utf16),
        "the reopened store continues from read-back truth without replay")
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  /// Bounded contention: a direct public entry cannot pass a reserved queued
  /// turn during its retry back-off, and exhausting maxQueueAttempts is a typed
  /// `publicationConflict` with no fake receipt, no publication and a still
  /// usable queue for a valid follower.
  private static func checkQueueRetryExhaustion(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }

    let fault = QueueFaultVault()
    let vault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let store = PiliAccountEnvelopeTransactionStore(
      vault: vault, maxQueueAttempts: 50, retryDelayNanoseconds: 1_000_000_000)
    let interveningVault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let intervening = PiliAccountEnvelopeTransactionStore(vault: interveningVault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard case .identity(let adopt) = try await store.enqueue(.adoptIdentities) else {
        throw QueueFixtureError.failed("identity adoption for the retry contract expected")
      }
      let identity1 = adopt.adoptedIdentities[0]
      guard let before = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing retry base snapshot")
      }
      await fault.pauseManifestReadAfter(1)
      let queued = Task { try await store.enqueue(.cookieDeleteAll(recordKey: fx.key,
        generation: fx.record.generation)) }
      try await waitForManifestReadPaused(fault)
      _ = try await intervening.applyCredentials(recordKeyUnits: fx.key,
        expectedGeneration: fx.record.generation,
        accessKeyUnits: units("retry-intervening"), refreshTokenUnits: nil)
      await fault.resumeManifestRead()
      try await waitForRetrySleep(store, 1)
      // The queued turn is sleeping between attempts; a direct public write
      // must not enter ahead of the admitted queue work.
      let idleDuringRetry = await store.writeQueueIdle
      try check(!idleDuringRetry, "the writer role stays reserved during retry back-off")
      var directFenced = false
      do {
        _ = try await store.applyCredentials(recordKeyUnits: fx.key,
          expectedGeneration: fx.record.generation,
          accessKeyUnits: units("must-not-enter"), refreshTokenUnits: nil)
      } catch PiliAccountShadowTransactionError.operationInProgress { directFenced = true }
      try check(directFenced, "direct entry cannot pass a queued turn in retry back-off")
      guard case .record(let retried) = try await queued.value else {
        throw QueueFixtureError.failed("retried queued outcome is not a record receipt")
      }
      try check(retried.durableIdentity == identity1,
                "the retried queued write kept its identity after recomputation")
      guard let after = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing retry final snapshot")
      }
      try check(after.envelope.records[1].jar == fx.cleared &&
        after.envelope.records[1].accessKeyUnits?.units == Array("retry-intervening".utf16),
        "the retried transform re-read the fresh snapshot exactly once")
      try check(await fault.recordCount() == 4,
                "the rejected direct entry published nothing")
      try check(before.transactionID != after.transactionID,
                "the queued retry published its own candidate")
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }

    let chaosFault = QueueFaultVault()
    let chaosVault = PiliAccountEnvelopeStagingStore(secrets: chaosFault)
    let chaosStore = PiliAccountEnvelopeTransactionStore(
      vault: chaosVault, maxQueueAttempts: 3, retryDelayNanoseconds: 100_000_000)
    let chaosInterveningVault = PiliAccountEnvelopeStagingStore(secrets: chaosFault)
    let chaosIntervening = PiliAccountEnvelopeTransactionStore(vault: chaosInterveningVault)
    do {
      try await chaosVault.importShadow(fx.codec.encode(fx.base))
      _ = try await chaosStore.enqueue(.adoptIdentities)
      await chaosFault.pauseManifestReadAfter(1)
      let queued = Task { try await chaosStore.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("conflict-queued"),
        refreshToken: nil)) }
      for round in 1...3 {
        try await waitForManifestReadPaused(chaosFault)
        _ = try await chaosIntervening.applyCredentials(recordKeyUnits: fx.key,
          expectedGeneration: fx.record.generation,
          accessKeyUnits: units("conflict-\(round)"), refreshTokenUnits: nil)
        await chaosFault.resumeManifestRead()
        if round < 3 {
          try await waitForRetrySleep(chaosStore, round)
          await chaosFault.pauseManifestReadAfter(1)
        }
      }
      var exhausted = false
      do {
        _ = try await queued.value
        throw QueueFixtureError.failed("exhausted queued write fabricated a receipt")
      } catch PiliAccountShadowTransactionError.publicationConflict { exhausted = true }
      try check(exhausted,
                "contention exhaustion is a typed conflict, never a fake receipt")
      try check(await chaosStore.pendingUnresolvedPublication == nil,
                "contention exhaustion is not an unknown-publication fence")
      guard let conflictFinal = try await chaosStore.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing conflict final snapshot")
      }
      try check(conflictFinal.envelope.records[1].accessKeyUnits?.units ==
        Array("conflict-3".utf16),
        "the exhausted queued write never published over the last intervening write")
      try check(await chaosFault.recordCount() == 5,
                "exactly base+adopt+three interventions were published")
      guard case .record(let conflictFollower) = try await chaosStore.enqueue(.credentials(
        recordKey: fx.key, generation: fx.record.generation,
        accessKey: units("after-conflict"), refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after contention exhaustion expected")
      }
      try check(conflictFollower.record == 1,
                "the follower after contention exhaustion publishes normally")
      guard let conflictAfter = try await chaosStore.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-conflict snapshot")
      }
      try check(conflictAfter.envelope.records[1].accessKeyUnits?.units ==
        Array("after-conflict".utf16),
        "the queue keeps draining after the bounded conflict")
      try await chaosVault.discardShadow()
    } catch {
      try? await chaosVault.discardShadow()
      throw error
    }
    return checks
  }

  /// A queued purpose change interrupted between read and publish must retry on
  /// a fresh snapshot (recompute, preserving the intervening write), and a
  /// named previous holder invalidated by that intervention must be rejected
  /// with zero stale side effects. No global purpose uniqueness is implied.
  private static func checkQueuedPurposeInterference(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }

    let fault = QueueFaultVault()
    let vault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let store = PiliAccountEnvelopeTransactionStore(
      vault: vault, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    let interveningVault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let intervening = PiliAccountEnvelopeTransactionStore(vault: interveningVault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard case .identity(let adopt) = try await store.enqueue(.adoptIdentities) else {
        throw QueueFixtureError.failed("identity adoption for purpose interference expected")
      }
      let identity1 = adopt.adoptedIdentities[0]
      let initialFirst = fx.base.records[1].persistedPurposes
      let initialSecond = fx.base.records[2].persistedPurposes
      let purpose = PiliAccountPurpose.recommend

      // The queued purpose change loads, then an intervening credentials write
      // publishes; the stale candidate is rejected and recomputed.
      await fault.pauseManifestReadAfter(1)
      let queued = Task { try await store.enqueue(.purposeChange(recordKey: fx.key,
        generation: fx.record.generation, purpose: purpose, previousKey: fx.key2,
        previousGeneration: fx.generation2)) }
      try await waitForManifestReadPaused(fault)
      _ = try await intervening.applyCredentials(recordKeyUnits: fx.key,
        expectedGeneration: fx.record.generation,
        accessKeyUnits: units("purpose-intervening"), refreshTokenUnits: nil)
      await fault.resumeManifestRead()
      guard case .record(let purposeReceipt) = try await queued.value else {
        throw QueueFixtureError.failed("queued purpose receipt expected")
      }
      try check(purposeReceipt.durableIdentity == identity1 && purposeReceipt.record == 1,
                "the queued purpose receipt carries the selected identity")
      guard let after = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing purpose interference snapshot")
      }
      try check(after.envelope.records[1].accessKeyUnits?.units ==
        Array("purpose-intervening".utf16),
        "the recomputed purpose candidate preserved the intervening credentials")
      try check(after.envelope.records[1].persistedPurposes ==
        (initialFirst.contains(purpose) ? initialFirst : initialFirst + [purpose]),
        "the selected record gains the purpose in Dart append order")
      try check(after.envelope.records[2].persistedPurposes ==
        initialSecond.filter { $0 != purpose },
        "the named previous holder loses the purpose")
      try check(after.envelope.selections[2] == after.envelope.records[1].record,
                "the purpose slot points at the selected record")
      let heartbeat = after.envelope.selections[1]
      try check(after.envelope.history == (after.envelope.records[heartbeat].isLogin
        ? heartbeat : after.envelope.selections[0]),
        "history follows the existing derivation policy")
      let candidate = try await vault.loadPublishedCandidate(
        transactionID: purposeReceipt.transactionID)
      try check(candidate == after.envelope &&
        candidate.records[2].persistedPurposes == initialSecond.filter { $0 != purpose },
        "the receipt names the recomputed immutable candidate")
      try check(await fault.recordCount() == 4,
                "the rejected stale purpose candidate was never published")
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }

    let rejectFault = QueueFaultVault()
    let rejectVault = PiliAccountEnvelopeStagingStore(secrets: rejectFault)
    let rejectStore = PiliAccountEnvelopeTransactionStore(
      vault: rejectVault, maxQueueAttempts: 800, retryDelayNanoseconds: 5_000_000)
    let rejectInterveningVault = PiliAccountEnvelopeStagingStore(secrets: rejectFault)
    let rejectIntervening = PiliAccountEnvelopeTransactionStore(vault: rejectInterveningVault)
    do {
      try await rejectVault.importShadow(fx.codec.encode(fx.base))
      _ = try await rejectStore.enqueue(.adoptIdentities)
      // A real setup write makes the first record the named previous holder.
      guard case .record = try await rejectStore.enqueue(.purposeChange(
        recordKey: fx.key, generation: fx.record.generation, purpose: .main,
        previousKey: nil, previousGeneration: nil)) else {
        throw QueueFixtureError.failed("purpose setup write expected")
      }
      await rejectFault.pauseManifestReadAfter(1)
      let queued = Task { try await rejectStore.enqueue(.purposeChange(recordKey: fx.key2,
        generation: fx.generation2, purpose: .main, previousKey: fx.key,
        previousGeneration: fx.record.generation)) }
      try await waitForManifestReadPaused(rejectFault)
      // The intervening import replaces the previous holder's generation, so
      // the recomputed transform must reject the named precondition.
      _ = try await rejectIntervening.applyImport([PiliAccountShadowInstall(
        storageKeyUnits: fx.key, mid: fx.record.mid,
        generation: fx.record.generation + 700, accessKeyUnits: nil,
        refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: fx.cleared)])
      guard let afterIntervening = try await rejectIntervening.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing purpose rejection snapshot")
      }
      await rejectFault.resumeManifestRead()
      var staleRejected = false
      do {
        _ = try await queued.value
      } catch PiliAccountShadowTransactionError.staleGeneration { staleRejected = true }
      try check(staleRejected,
                "the invalidated previous holder is rejected on recomputation")
      guard let afterReject = try await rejectStore.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-rejection snapshot")
      }
      try check(afterReject.transactionID == afterIntervening.transactionID &&
        afterReject.envelope == afterIntervening.envelope,
        "the rejected purpose change has zero stale side effects")
      try check(await rejectFault.recordCount() == 4,
                "the rejected purpose change published nothing")
      try await rejectVault.discardShadow()
    } catch {
      try? await rejectVault.discardShadow()
      throw error
    }
    return checks
  }

  /// R19: content equality is not attempted-publication identity. No-op
  /// same-value credentials/activation writes exercise write-before and
  /// write-after unknown failures; resolution must classify by the exact
  /// attempted transaction ID, never by bytes. A byte-identical foreign
  /// candidate is explicitly ambiguous. Nothing is auto-replayed.
  private static func checkSameValueResolutionIdentity(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let fault = QueueFaultVault()
    let vault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard case .identity = try await store.enqueue(.adoptIdentities) else {
        throw QueueFixtureError.failed("identity adoption for the same-value contract expected")
      }
      guard let baseline = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing same-value baseline")
      }
      let baselineRecords = await fault.recordCount()
      let baselineAccess = baseline.envelope.records[1].accessKeyUnits
      let baselineRefresh = baseline.envelope.records[1].refreshTokenUnits
      let baselineActivated = baseline.envelope.records[1].activated

      // Same-value credentials, write-before error + unreadable acknowledgment:
      // the pointer never moved although the bytes match exactly.
      await fault.arm(.pointerWriteBefore)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.applyCredentials(recordKeyUnits: fx.key,
          expectedGeneration: fx.record.generation, accessKeyUnits: baselineAccess,
          refreshTokenUnits: baselineRefresh)
        throw QueueFixtureError.failed("same-value write-before-error fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let unresolvedBefore = await store.pendingUnresolvedPublication else {
        throw QueueFixtureError.failed("same-value write-before-error left no fence")
      }
      guard let notCommitted = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("same-value write-before-error fence did not resolve")
      }
      try check(notCommitted.outcome == .attemptNotCommitted &&
        notCommitted.observedTransactionID == notCommitted.expectedPreviousTransactionID &&
        notCommitted.observedContentMatchesAttempt &&
        notCommitted.attemptedTransactionID == unresolvedBefore.attemptedTransactionID,
        "a byte-identical write-before attempt is not committed, never matched by content")
      try check(await fault.recordCount() == baselineRecords + 1,
        "the byte-identical write-before attempt leaves one retained raw candidate")

      // Same-value credentials, write-after error + unreadable acknowledgment:
      // the pointer committed under the exact attempted ID although the bytes
      // equal the previous candidate.
      await fault.arm(.pointerWriteAfter)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: baselineAccess,
          refreshToken: baselineRefresh))
        throw QueueFixtureError.failed("same-value write-after-error fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let unresolvedAfter = await store.pendingUnresolvedPublication else {
        throw QueueFixtureError.failed("same-value write-after-error left no fence")
      }
      try check(unresolvedAfter.attemptedTransactionID != unresolvedBefore.attemptedTransactionID,
                "distinct attempts keep distinct immutable IDs even with identical bytes")
      guard let committed = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("same-value write-after-error fence did not resolve")
      }
      try check(committed.outcome == .attemptCommitted &&
        committed.observedTransactionID == committed.attemptedTransactionID &&
        committed.observedContentMatchesAttempt,
        "a committed byte-identical attempt is proven by exact operation identity")
      guard let pointerAfterCommitted = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-committed pointer")
      }
      try check(pointerAfterCommitted.transactionID == committed.attemptedTransactionID,
        "the committed candidate is the actual published manifest, not a raw orphan")
      try check(await fault.recordCount() == baselineRecords + 2,
        "the committed attempt adds its raw candidate alongside the retained one")

      // Same-value activation on both sides of the failure boundary.
      await fault.arm(.pointerWriteBefore)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.enqueue(.activated(recordKey: fx.key,
          generation: fx.record.generation, activated: baselineActivated))
        throw QueueFixtureError.failed("same-value activation before-error fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let activationBefore = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("same-value activation before-error fence did not resolve")
      }
      try check(activationBefore.outcome == .attemptNotCommitted &&
        activationBefore.observedContentMatchesAttempt,
        "a byte-identical activation write-before attempt is not committed")
      await fault.arm(.pointerWriteAfter)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.enqueue(.activated(recordKey: fx.key,
          generation: fx.record.generation, activated: baselineActivated))
        throw QueueFixtureError.failed("same-value activation after-error fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let activationAfter = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("same-value activation after-error fence did not resolve")
      }
      try check(activationAfter.outcome == .attemptCommitted &&
        activationAfter.observedTransactionID == activationAfter.attemptedTransactionID &&
        activationAfter.observedContentMatchesAttempt,
        "a committed byte-identical activation is proven by exact operation identity")

      // A foreign store publishes a byte-identical no-op candidate while this
      // store is fenced: the read-back must be explicitly ambiguous, never
      // claimed as this attempt.
      await fault.arm(.pointerWriteBefore)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: baselineAccess,
          refreshToken: baselineRefresh))
        throw QueueFixtureError.failed("ambiguity attempt fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let ambiguousPending = await store.pendingUnresolvedPublication else {
        throw QueueFixtureError.failed("ambiguity attempt left no pending operation")
      }
      // The namespace journal blocks every second correlated publisher, so the
      // out-of-contract foreign byte-identical candidate is produced by the raw
      // uncorrelated import primitive: the journal survives and the read-back
      // must be explicitly ambiguous, never claimed as this attempt.
      let foreignVault = PiliAccountEnvelopeStagingStore(secrets: fault)
      guard let currentWhileFenced = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing fenced snapshot for the foreign candidate")
      }
      _ = try await foreignVault.importShadow(fx.codec.encode(currentWhileFenced.envelope))
      // R24: an ambiguous read-back is never auto-resolved. The default
      // resolution must fail closed with the durable journal and the fence
      // both intact; otherwise a crash after the default resolution would lose
      // the only correlation evidence for this attempt.
      var ambiguousBlocked = false
      do {
        _ = try await store.resolveUnresolvedPublication()
      } catch PiliAccountShadowTransactionError.ambiguousRecovery { ambiguousBlocked = true }
      try check(ambiguousBlocked,
        "an ambiguous read-back keeps the durable evidence until an explicit acknowledgment")
      guard let retainedJournal = try await vault.loadRecoveryJournal() else {
        throw QueueFixtureError.failed("default ambiguity resolution deleted the durable journal")
      }
      try check(retainedJournal.attemptedTransactionID == ambiguousPending.attemptedTransactionID &&
        retainedJournal.expectedPreviousTransactionID == ambiguousPending.expectedPreviousTransactionID,
        "the retained journal still names the ambiguous attempted operation")
      var stillFenced = false
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-cross-ambiguity"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { stillFenced = true }
      try check(stillFenced, "the ambiguous operation still fences every later write")
      // A fresh store over the same persistent journal must see the same
      // unresolved evidence: an empty in-memory state never erases it.
      let ambiguousRestarted = PiliAccountEnvelopeTransactionStore(
        vault: PiliAccountEnvelopeStagingStore(secrets: fault))
      guard let restartedPending = try await ambiguousRestarted.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("reopen lost the ambiguous pending operation")
      }
      try check(restartedPending.attemptedTransactionID == ambiguousPending.attemptedTransactionID,
        "reopen keeps the ambiguous attempted operation identity")
      // A cancelled explicit acknowledgment keeps both journal and fence.
      await fault.pauseManifestReadAfter(0)
      let cancelledAck = Task { try await store.resolveUnresolvedPublication(allowAmbiguous: true) }
      try await waitForManifestReadPaused(fault)
      cancelledAck.cancel()
      await fault.resumeManifestRead()
      var cancelledAcknowledgment = false
      do {
        _ = try await cancelledAck.value
      } catch is CancellationError { cancelledAcknowledgment = true }
      try check(cancelledAcknowledgment,
        "a cancelled ambiguity acknowledgment resolves nothing")
      guard try await vault.loadRecoveryJournal() != nil else {
        throw QueueFixtureError.failed("a cancelled ambiguity acknowledgment deleted the journal")
      }
      guard await store.pendingUnresolvedPublication != nil else {
        throw QueueFixtureError.failed("a cancelled ambiguity acknowledgment released the fence")
      }
      // Only the explicit acknowledgment records the ambiguity in the returned
      // receipt and durably clears the journal before releasing the fence.
      guard let ambiguous = try await store.resolveUnresolvedPublication(allowAmbiguous: true) else {
        throw QueueFixtureError.failed("identical-byte foreign candidate left no resolution")
      }
      try check(ambiguous.outcome == .ambiguousObservedCandidate &&
        ambiguous.observedContentMatchesAttempt &&
        ambiguous.observedTransactionID != ambiguous.attemptedTransactionID &&
        ambiguous.observedTransactionID != ambiguous.expectedPreviousTransactionID &&
        ambiguous.attemptedTransactionID == ambiguousPending.attemptedTransactionID,
        "an identical-byte foreign candidate is ambiguous, never claimed as this attempt")
      guard try await vault.loadRecoveryJournal() == nil else {
        throw QueueFixtureError.failed("the explicit ambiguity acknowledgment did not clear the journal")
      }
      guard let unchangedPointer = try await store.loadShadowSnapshot(),
            unchangedPointer.transactionID == ambiguous.observedTransactionID,
            unchangedPointer.envelope == currentWhileFenced.envelope else {
        throw QueueFixtureError.failed("the ambiguity acknowledgment replayed or moved the foreign pointer")
      }
      checks += 1
      guard case .record = try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-ambiguity"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after ambiguity expected")
      }
      try await waitForIdle(store)
      guard let afterAmbiguity = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-ambiguity snapshot")
      }
      try check(afterAmbiguity.envelope.records[1].accessKeyUnits?.units ==
        Array("after-ambiguity".utf16),
        "the released store continues from read-back truth after ambiguity")
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  /// R20: resolution is single-flight, cancellation-aware and revalidates the
  /// immutable pending-operation token after every await, so a stale resolver
  /// can never release a newer fence.
  private static func checkResolutionSerialization(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let fault = QueueFaultVault()
    let vault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      _ = try await store.enqueue(.adoptIdentities)
      guard let originalPointer = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing serialization baseline pointer")
      }
      let baselineRecords = await fault.recordCount()
      try check(baselineRecords == 2,
                "the immutable baseline holds only the imported and adopted candidates")

      // Undecided unknown A: write-before + unreadable acknowledgment. The vault
      // writes and verifies the candidate record + descriptor first and then
      // cannot decide the pointer write, so it intentionally RETAINS that raw
      // candidate while the publication stays unknown. A retained raw candidate
      // is not a published pointer; prove the two separately.
      await fault.arm(.pointerWriteBefore)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("resolution-a"),
          refreshToken: nil))
        throw QueueFixtureError.failed("resolution A fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let pendingA = await store.pendingUnresolvedPublication else {
        throw QueueFixtureError.failed("resolution A left no fence")
      }
      guard let pointerAfterUnknownA = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-unknown-A pointer")
      }
      try check(pointerAfterUnknownA.transactionID == originalPointer.transactionID &&
        pointerAfterUnknownA.envelope == originalPointer.envelope,
        "the write-before unknown leaves the published manifest unchanged")
      try check(pendingA.attemptedTransactionID != originalPointer.transactionID,
                "the attempted operation ID is distinct from the unchanged pointer")
      let retainedA = try await vault.loadPublishedCandidate(
        transactionID: pendingA.attemptedTransactionID)
      try check(retainedA.records[1].accessKeyUnits?.units == Array("resolution-a".utf16),
                "the attempted immutable candidate is retained but not published")
      try check(await fault.recordCount() == baselineRecords + 1,
                "exactly one raw attempted candidate is retained beyond the baseline")

      // Hold resolver one inside its read-back; resolver two must fail closed
      // and must not clear the still-pending fence.
      await fault.pauseManifestReadAfter(0)
      let resolverOne = Task { try await store.resolveUnresolvedPublication() }
      try await waitForManifestReadPaused(fault)
      var overlapping = false
      do {
        _ = try await store.resolveUnresolvedPublication()
      } catch PiliAccountShadowTransactionError.resolutionInProgress { overlapping = true }
      try check(overlapping, "concurrent resolution fails closed instead of racing the fence")
      let inFlightFence: PiliAccountShadowUnresolvedPublication? =
        await store.pendingUnresolvedPublication
      try check(inFlightFence?.attemptedTransactionID == pendingA.attemptedTransactionID,
                "an in-flight resolver never clears its fence early")
      await fault.resumeManifestRead()
      guard let firstResolution = try await resolverOne.value else {
        throw QueueFixtureError.failed("resolver one returned no resolution")
      }
      let fenceClearedAfterFirst: PiliAccountShadowUnresolvedPublication? =
        await store.pendingUnresolvedPublication
      try check(firstResolution.outcome == .attemptNotCommitted &&
        fenceClearedAfterFirst == nil,
        "the first resolver records its read-back and releases only its own fence")
      try check(firstResolution.observedTransactionID == originalPointer.transactionID,
                "the correlated resolution observes the unchanged original pointer")
      guard let pointerAfterResolutionA = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-resolution-A pointer")
      }
      try check(pointerAfterResolutionA.transactionID == originalPointer.transactionID &&
        pointerAfterResolutionA.envelope == originalPointer.envelope,
        "not-committed resolution records read-back without replay or publication")
      let retainedAStillThere = try await vault.loadPublishedCandidate(
        transactionID: pendingA.attemptedTransactionID)
      let recordsAfterResolutionA = await fault.recordCount()
      try check(retainedAStillThere == retainedA &&
        recordsAfterResolutionA == baselineRecords + 1,
        "the retained attempt and its exact raw count survive the recorded resolution")

      // A new unknown B after A resolved: new immutable ID, fenced followers,
      // and survival of a cancelled stale resolver.
      await fault.arm(.pointerWriteBefore)
      await fault.failPointerReadAfter(2)
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("resolution-b"),
          refreshToken: nil))
        throw QueueFixtureError.failed("resolution B fabricated success")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { checks += 1 }
      guard let pendingB = await store.pendingUnresolvedPublication else {
        throw QueueFixtureError.failed("resolution B left no fence")
      }
      try check(pendingB.attemptedTransactionID != pendingA.attemptedTransactionID,
                "a new unknown keeps a new immutable ID")
      guard let pointerAfterUnknownB = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-unknown-B pointer")
      }
      try check(pointerAfterUnknownB.transactionID == originalPointer.transactionID &&
        pointerAfterUnknownB.envelope == originalPointer.envelope,
        "the second write-before unknown also leaves the published manifest unchanged")
      let retainedB = try await vault.loadPublishedCandidate(
        transactionID: pendingB.attemptedTransactionID)
      try check(retainedB.records[1].accessKeyUnits?.units == Array("resolution-b".utf16),
                "the second attempted immutable candidate is retained but not published")
      try check(await fault.recordCount() == baselineRecords + 2,
                "both retained attempts keep distinct raw candidates")
      var followerFenced = false
      do {
        _ = try await store.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-cross-b"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { followerFenced = true }
      try check(followerFenced, "queued followers never cross an unresolved boundary")

      // A cancelled resolver must keep B armed and release the single-flight
      // gate for a later resolution.
      await fault.pauseManifestReadAfter(0)
      let cancelledResolver = Task { try await store.resolveUnresolvedPublication() }
      try await waitForManifestReadPaused(fault)
      cancelledResolver.cancel()
      await fault.resumeManifestRead()
      var cancelledResolution = false
      do {
        _ = try await cancelledResolver.value
      } catch is CancellationError { cancelledResolution = true }
      try check(cancelledResolution, "a cancelled resolver never releases the fence")
      let fenceSurvivedB: PiliAccountShadowUnresolvedPublication? =
        await store.pendingUnresolvedPublication
      try check(fenceSurvivedB?.attemptedTransactionID == pendingB.attemptedTransactionID,
                "fence B survives the cancelled stale resolver")
      guard let secondResolution = try await store.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("resolution B did not resolve after the cancelled resolver")
      }
      try check(secondResolution.outcome == .attemptNotCommitted &&
        secondResolution.attemptedTransactionID == pendingB.attemptedTransactionID,
        "resolution B classifies its own immutable token after the cancelled resolver")
      try check(secondResolution.observedTransactionID == originalPointer.transactionID,
                "resolution B also observes the unchanged original pointer")
      guard case .record = try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-b"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after resolution B expected")
      }
      guard let afterB = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-resolution-B snapshot")
      }
      try check(afterB.envelope.records[1].accessKeyUnits?.units ==
        Array("after-b".utf16),
        "the queue drains normally after resolution B")
      try check(afterB.transactionID != pendingA.attemptedTransactionID &&
        afterB.transactionID != pendingB.attemptedTransactionID,
        "the follower publishes a new manifest, never a replayed retained candidate")
      try check(await fault.recordCount() == baselineRecords + 3,
        "only the explicit follower added a published candidate beyond the retained attempts")
      try await vault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  /// B2e-2: the durable recovery journal survives store recreation; a recreated
  /// store arms its fence from persisted evidence, resolves by exact operation
  /// identity and only then admits followers. Corrupt or unverifiable journals
  /// fail closed and are never read as absent.
  private static func checkPersistentRecoveryJournal(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }

    // Part 1: committed unknown (write after error + unreadable ack) reopened.
    let fault = QueueFaultVault()
    let vault = PiliAccountEnvelopeStagingStore(secrets: fault)
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      _ = try await store.enqueue(.adoptIdentities)
      await fault.arm(.pointerReadAfter)
      let unknown = Task { try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("journal-committed"),
        refreshToken: nil)) }
      var surfaced = false
      do {
        _ = try await unknown.value
        throw QueueFixtureError.failed("journaled unknown fabricated a receipt")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced = true }
      try check(surfaced, "the journaled unknown still propagates instead of a fake receipt")
      guard let journal = try await vault.loadRecoveryJournal() else {
        throw QueueFixtureError.failed("unknown publication left no durable journal")
      }
      try check(journal.kind == "credentials" && journal.attemptedCandidateSHA256.count == 64,
                "the durable journal carries the attempted operation evidence")
      let restartedVault = PiliAccountEnvelopeStagingStore(secrets: fault)
      let restarted = PiliAccountEnvelopeTransactionStore(vault: restartedVault)
      guard let pending = try await restarted.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("recreated store lost the durable fence")
      }
      try check(pending.attemptedTransactionID == journal.attemptedTransactionID &&
        pending.expectedPreviousTransactionID == journal.expectedPreviousTransactionID,
        "the recreated fence matches the durable journal identity")
      var fenced = false
      do {
        _ = try await restarted.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-overwrite"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { fenced = true }
      try check(fenced, "a recreated store cannot admit an overwriting follower")
      guard let resolution = try await restarted.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("recreated store did not resolve")
      }
      try check(resolution.outcome == .attemptCommitted &&
        resolution.observedTransactionID == resolution.attemptedTransactionID,
        "the recreated store classifies the committed attempt by identity")
      guard try await restartedVault.loadRecoveryJournal() == nil else {
        throw QueueFixtureError.failed("resolution did not durably clear the journal")
      }
      guard case .record = try await restarted.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("journal-after"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after journal resolution expected")
      }
      try await waitForIdle(restarted)
      try await restartedVault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }

    // Part 2: uncommitted unknown (write before error + unreadable ack) reopened.
    let fault2 = QueueFaultVault()
    let vault2 = PiliAccountEnvelopeStagingStore(secrets: fault2)
    let store2 = PiliAccountEnvelopeTransactionStore(vault: vault2)
    do {
      try await vault2.importShadow(fx.codec.encode(fx.base))
      _ = try await store2.enqueue(.adoptIdentities)
      await fault2.arm(.pointerWriteBefore)
      await fault2.failPointerReadAfter(2)
      var surfaced2 = false
      do {
        _ = try await store2.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-uncommitted"),
          refreshToken: nil))
        throw QueueFixtureError.failed("uncommitted journaled unknown fabricated a receipt")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced2 = true }
      try check(surfaced2, "the uncommitted journaled unknown propagates")
      guard let journal2 = try await vault2.loadRecoveryJournal() else {
        throw QueueFixtureError.failed("write-before unknown left no durable journal")
      }
      let restarted2 = PiliAccountEnvelopeTransactionStore(
        vault: PiliAccountEnvelopeStagingStore(secrets: fault2))
      guard let pending2 = try await restarted2.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("recreated store lost the uncommitted fence")
      }
      try check(pending2.attemptedTransactionID == journal2.attemptedTransactionID,
                "the uncommitted fence matches its durable journal")
      guard let resolution2 = try await restarted2.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("uncommitted resolution missing")
      }
      try check(resolution2.outcome == .attemptNotCommitted &&
        resolution2.observedTransactionID == resolution2.expectedPreviousTransactionID,
        "the recreated store classifies the uncommitted attempt and keeps the pointer")
      guard try await vault2.loadRecoveryJournal() == nil else {
        throw QueueFixtureError.failed("uncommitted resolution did not clear the journal")
      }
      try await vault2.discardShadow()
    } catch {
      try? await vault2.discardShadow()
      throw error
    }

    // Part 3: a corrupt journal fails closed for the live and recreated store
    // and blocks publication entirely.
    let fault3 = QueueFaultVault()
    let vault3 = PiliAccountEnvelopeStagingStore(secrets: fault3)
    let store3 = PiliAccountEnvelopeTransactionStore(vault: vault3)
    do {
      try await vault3.importShadow(fx.codec.encode(fx.base))
      _ = try await store3.enqueue(.adoptIdentities)
      try await fault3.write(Data("{\"not\":\"a journal\"}".utf8),
                             key: "account-envelope-recovery-journal-v1")
      var corruptRejected = false
      do {
        _ = try await store3.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("corrupt-must-not-publish"),
          refreshToken: nil))
      } catch PiliAccountEnvelopeStagingError.invalidRecoveryJournal { corruptRejected = true }
      try check(corruptRejected, "a corrupt journal fails closed instead of reading as absent")
      let restarted3 = PiliAccountEnvelopeTransactionStore(
        vault: PiliAccountEnvelopeStagingStore(secrets: fault3))
      var restartedCorrupt = false
      do {
        _ = try await restarted3.loadPersistentRecovery()
      } catch PiliAccountEnvelopeStagingError.invalidRecoveryJournal { restartedCorrupt = true }
      try check(restartedCorrupt, "a recreated store also fails closed on the corrupt journal")
      try check(await fault3.recordCount() == 2,
                "the corrupt journal blocked publication entirely")
      try await vault3.discardShadow()
    } catch {
      try? await vault3.discardShadow()
      throw error
    }

    // Part 4: journal write failures before/after commit leave no deadlock and
    // no leftover fence for a definite pre-publication failure.
    let fault4 = QueueFaultVault()
    let vault4 = PiliAccountEnvelopeStagingStore(secrets: fault4)
    let store4 = PiliAccountEnvelopeTransactionStore(vault: vault4)
    do {
      try await vault4.importShadow(fx.codec.encode(fx.base))
      _ = try await store4.enqueue(.adoptIdentities)
      await fault4.arm(.journalWriteBefore)
      var beforeFailed = false
      do {
        _ = try await store4.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-write-before"),
          refreshToken: nil))
        throw QueueFixtureError.failed("journal write-before failure accepted")
      } catch QueueFixtureError.injected { beforeFailed = true }
      try check(beforeFailed, "a journal write failure before commit surfaces")
      guard try await vault4.loadRecoveryJournal() == nil else {
        throw QueueFixtureError.failed("write-before failure left a journal")
      }
      try check(await store4.pendingUnresolvedPublication == nil,
                "a definite pre-publication journal failure leaves no fence")
      guard case .record = try await store4.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-journal-before"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after journal write-before expected")
      }
      try check(await fault4.recordCount() == 3,
                "the failed journal write published no candidate")

      await fault4.arm(.journalWriteAfter)
      var afterFailed = false
      do {
        _ = try await store4.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-write-after"),
          refreshToken: nil))
        throw QueueFixtureError.failed("journal write-after failure accepted")
      } catch QueueFixtureError.injected { afterFailed = true }
      try check(afterFailed, "a journal write failure after commit surfaces")
      guard try await vault4.loadRecoveryJournal() == nil else {
        throw QueueFixtureError.failed("write-after failure left an unverifiable journal")
      }
      try check(await store4.pendingUnresolvedPublication == nil,
                "the verified clear restores a definite pre-publication state")
      guard case .record = try await store4.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-journal-after"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after journal write-after expected")
      }
      try check(await fault4.recordCount() == 4,
                "the cleared journal attempt published no candidate")
      try await vault4.discardShadow()
    } catch {
      try? await vault4.discardShadow()
      throw error
    }

    // Part 5: cancellation keeps the durable journal and unverifiable journal
    // reads fail resolution closed until reads recover.
    let fault5 = QueueFaultVault()
    let vault5 = PiliAccountEnvelopeStagingStore(secrets: fault5)
    let store5 = PiliAccountEnvelopeTransactionStore(vault: vault5)
    do {
      try await vault5.importShadow(fx.codec.encode(fx.base))
      _ = try await store5.enqueue(.adoptIdentities)
      await fault5.arm(.pointerReadAfter)
      var surfaced5 = false
      do {
        _ = try await store5.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-unreadable"),
          refreshToken: nil))
        throw QueueFixtureError.failed("unreadable-journal unknown fabricated a receipt")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced5 = true }
      try check(surfaced5, "the unreadable-journal unknown propagates")
      let restarted5 = PiliAccountEnvelopeTransactionStore(
        vault: PiliAccountEnvelopeStagingStore(secrets: fault5))
      await fault5.pauseManifestReadAfter(0)
      let cancelledResolver = Task { try await restarted5.resolveUnresolvedPublication() }
      try await waitForManifestReadPaused(fault5)
      cancelledResolver.cancel()
      await fault5.resumeManifestRead()
      var cancelledResolution = false
      do {
        _ = try await cancelledResolver.value
      } catch is CancellationError { cancelledResolution = true }
      try check(cancelledResolution, "a cancelled resolver never releases the durable fence")
      guard try await vault5.loadRecoveryJournal() != nil else {
        throw QueueFixtureError.failed("cancelled resolver cleared the durable journal")
      }
      await fault5.failJournalReadsForever()
      var readFailureSurfaced = false
      do {
        _ = try await restarted5.resolveUnresolvedPublication()
      } catch QueueFixtureError.injected { readFailureSurfaced = true }
      try check(readFailureSurfaced, "an unreadable journal fails the resolution closed")
      let fenceStillArmed: PiliAccountShadowUnresolvedPublication? =
        await restarted5.pendingUnresolvedPublication
      try check(fenceStillArmed != nil,
                "the unreadable-journal resolution kept the fence armed")
      await fault5.allowJournalReads()
      guard let resolved5 = try await restarted5.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("unreadable-journal recovery did not resolve")
      }
      try check(resolved5.outcome == .attemptCommitted,
                "the recovered journal classifies the committed attempt")
      guard case .record = try await restarted5.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("unreadable-after"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after unreadable-journal recovery expected")
      }
      try await waitForIdle(restarted5)
      try await vault5.discardShadow()
    } catch {
      try? await vault5.discardShadow()
      throw error
    }

    // Part 6 (R23): a failed journal verification read is never treated as
    // journal absence. An unverifiable write keeps its evidence for
    // arm/resolution, and the definite pre-publication cleanup only concludes
    // after a successful nil read.
    let fault6 = QueueFaultVault()
    let vault6 = PiliAccountEnvelopeStagingStore(secrets: fault6)
    let store6 = PiliAccountEnvelopeTransactionStore(vault: vault6)
    do {
      try await vault6.importShadow(fx.codec.encode(fx.base))
      _ = try await store6.enqueue(.adoptIdentities)
      let baseline6 = await fault6.recordCount()

      // (a) The journal write commits but its verification read fails: the
      // store keeps the fail-closed fence from the retained journal and never
      // reports a definite (clean) verification failure.
      await fault6.failJournalReadAfter(1)
      var verificationReadFailed = false
      do {
        _ = try await store6.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-verify-fail"),
          refreshToken: nil))
        throw QueueFixtureError.failed("unverifiable journal verification accepted")
      } catch PiliAccountEnvelopeStagingError.unresolvedRecovery { verificationReadFailed = true }
      try check(verificationReadFailed,
        "a failed journal verification read never becomes a definite result")
      guard let retained6 = try await vault6.loadRecoveryJournal() else {
        throw QueueFixtureError.failed("failed verification read deleted the committed journal")
      }
      let armed6 = await store6.pendingUnresolvedPublication
      try check(armed6?.attemptedTransactionID == retained6.attemptedTransactionID,
        "the store arms the exact retained journal identity after a verification read failure")
      let restarted6 = PiliAccountEnvelopeTransactionStore(
        vault: PiliAccountEnvelopeStagingStore(secrets: fault6))
      guard let restartedPending6 = try await restarted6.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("reopen lost the verification-failure journal")
      }
      try check(restartedPending6.attemptedTransactionID == retained6.attemptedTransactionID,
        "reopen keeps the verification-failure journal identity")
      try check(await fault6.recordCount() == baseline6,
        "the verification-read failure published no candidate")
      var fenced6 = false
      do {
        _ = try await store6.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("must-not-cross-verify-failure"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { fenced6 = true }
      try check(fenced6, "the verification-read failure fence rejects later writes")
      guard let resolved6 = try await store6.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("retained verification-failure journal did not resolve")
      }
      try check(resolved6.outcome == .attemptNotCommitted,
        "the retained verification-failure journal classifies the never-published attempt")
      guard try await vault6.loadRecoveryJournal() == nil else {
        throw QueueFixtureError.failed("the resolved verification-failure journal was not cleared")
      }
      guard case .record = try await store6.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-verify-failure"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after verification-read failure expected")
      }
      try check(await fault6.recordCount() == baseline6 + 1,
        "the follower after a verification-read failure publishes exactly once")

      // (b) A journal write failure whose read-back is also unreadable fails
      // closed as unresolved recovery (never as the raw write error, never as
      // absence), and the definite cleanup only concludes after a successful
      // nil read.
      await fault6.arm(.journalWriteBefore)
      await fault6.failJournalReadAfter(1)
      var writeReadUnverifiable = false
      do {
        _ = try await store6.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-unreadable-write"),
          refreshToken: nil))
        throw QueueFixtureError.failed("unreadable journal write outcome accepted")
      } catch PiliAccountEnvelopeStagingError.unresolvedRecovery { writeReadUnverifiable = true }
      try check(writeReadUnverifiable,
        "an unreadable journal write outcome fails closed as unresolved recovery")
      try check(await fault6.recordCount() == baseline6 + 1,
        "the unreadable journal write outcome published no candidate")
      try check(await store6.pendingUnresolvedPublication == nil,
        "the strictly re-read absent journal leaves no fence")
      guard case .record = try await store6.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-unreadable-write"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after unreadable journal write expected")
      }
      try check(await fault6.recordCount() == baseline6 + 2,
        "the follower after an unreadable journal write publishes exactly once")

      // (c) A journal write that commits and then throws, with an unreadable
      // read-back, keeps the committed evidence and resolves by identity.
      await fault6.arm(.journalWriteAfter)
      await fault6.failJournalReadAfter(1)
      var afterUnverifiable = false
      do {
        _ = try await store6.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-after-unreadable"),
          refreshToken: nil))
        throw QueueFixtureError.failed("unreadable after-commit journal outcome accepted")
      } catch PiliAccountEnvelopeStagingError.unresolvedRecovery { afterUnverifiable = true }
      try check(afterUnverifiable,
        "an unreadable after-commit journal outcome fails closed as unresolved recovery")
      guard let retained6c = try await vault6.loadRecoveryJournal() else {
        throw QueueFixtureError.failed("after-commit unreadable journal removed the evidence")
      }
      let armed6c = await store6.pendingUnresolvedPublication
      try check(armed6c?.attemptedTransactionID == retained6c.attemptedTransactionID,
        "the after-commit unreadable journal arms the exact retained identity")
      guard let resolved6c = try await store6.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("after-commit unreadable journal did not resolve")
      }
      try check(resolved6c.outcome == .attemptNotCommitted,
        "the after-commit unreadable journal classifies the never-published attempt")
      guard case .record = try await store6.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-after-unreadable"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after after-commit unreadable journal expected")
      }
      try check(await fault6.recordCount() == baseline6 + 3,
        "the follower after an after-commit unreadable journal publishes exactly once")

      // (e) The journal commits and its removal fails while the write error
      // surfaces: the failed removal must keep the evidence and fail closed as
      // unresolved recovery instead of claiming a clean namespace.
      await fault6.arm(.journalWriteAfter)
      await fault6.failNextJournalRemovals(1)
      var removeFailed = false
      do {
        _ = try await store6.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-remove-failure"),
          refreshToken: nil))
        throw QueueFixtureError.failed("failed journal removal accepted")
      } catch PiliAccountEnvelopeStagingError.unresolvedRecovery { removeFailed = true }
      try check(removeFailed,
        "a failed journal removal keeps the evidence and fails closed")
      guard let retained6e = try await vault6.loadRecoveryJournal() else {
        throw QueueFixtureError.failed("failed journal removal lost the evidence")
      }
      let armed6e = await store6.pendingUnresolvedPublication
      try check(armed6e?.attemptedTransactionID == retained6e.attemptedTransactionID,
        "the failed journal removal arms the exact retained identity")
      guard let resolved6e = try await store6.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("failed journal removal did not resolve")
      }
      try check(resolved6e.outcome == .attemptNotCommitted,
        "the failed-removal journal classifies the never-published attempt")
      guard case .record = try await store6.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-remove-failure"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after failed journal removal expected")
      }
      try check(await fault6.recordCount() == baseline6 + 4,
        "the follower after a failed journal removal publishes exactly once")

      // (d) Persistent verification-read failure cannot erase evidence: after
      // reads recover, the vault pre-check still refuses correlated writes
      // until the retained journal is resolved, and the backstop arms the
      // exact persisted identity instead of inventing one.
      await fault6.failJournalReadAfter(1, failures: Int.max)
      var persistentVerifyFailure = false
      do {
        _ = try await store6.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-persistent-fail"),
          refreshToken: nil))
      } catch { persistentVerifyFailure = true }
      try check(persistentVerifyFailure,
        "a persistently unreadable verification read fails closed")
      await fault6.allowJournalReads()
      guard let retained6d = try await vault6.loadRecoveryJournal() else {
        throw QueueFixtureError.failed("persistent verification failure removed the journal")
      }
      var backstop6d = false
      do {
        _ = try await store6.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("journal-backstop"),
          refreshToken: nil))
      } catch PiliAccountEnvelopeStagingError.unresolvedRecovery { backstop6d = true }
      try check(backstop6d,
        "the recovered journal still fences correlated writes through the vault pre-check")
      let armed6d = await store6.pendingUnresolvedPublication
      try check(armed6d?.attemptedTransactionID == retained6d.attemptedTransactionID,
        "the vault backstop arms the exact retained journal identity")
      guard let resolved6d = try await store6.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("backstop journal did not resolve")
      }
      try check(resolved6d.outcome == .attemptNotCommitted,
        "the backstop journal classifies the never-published attempt")
      guard case .record = try await store6.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("after-persistent-failure"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("follower after persistent verification failure expected")
      }
      try check(await fault6.recordCount() == baseline6 + 5,
        "the follower after a persistent verification failure publishes exactly once")
      try await vault6.discardShadow()
    } catch {
      try? await vault6.discardShadow()
      throw error
    }
    return checks
  }

  /// R25: actual isolated Keychain persistence for a pending recovery journal.
  /// Each phase materializes a distinct crash prefix directly in the real
  /// Keychain (journal-only; journal + retained raw candidate; journal +
  /// committed pointer; journal + foreign/ambiguous pointer) and reads it back
  /// with fresh secret-store/vault/store clients over the same namespace. This
  /// proves Keychain persistence across a client reopen; it does not simulate
  /// a process kill and makes no such claim. Injected read/removal failures
  /// have no seam in the real Keychain, so those boundaries stay covered by
  /// the fault-vault scheduler phases (including R23 cleanup reads). Raw
  /// retained candidate bytes are never treated as proof of a committed
  /// manifest.
  private static func checkPersistentRecoveryKeychain(_ fx: QueueFixture) async throws -> Int {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw QueueFixtureError.failed(label) }
      checks += 1
    }
    let namespace = UUID()
    func freshStore() -> PiliAccountEnvelopeTransactionStore {
      PiliAccountEnvelopeTransactionStore(
        vault: PiliAccountEnvelopeStagingStore(
          secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace)))
    }
    func freshSecrets() -> PiliAccountKeychainSecretStore {
      PiliAccountKeychainSecretStore(stagingNamespace: namespace)
    }
    let journalKey = PiliAccountEnvelopeRecoveryJournal.journalKey
    let vault = PiliAccountEnvelopeStagingStore(secrets: freshSecrets())
    do {
      try await vault.importShadow(fx.codec.encode(fx.base))
      guard let baseline = try await vault.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("keychain recovery baseline missing")
      }

      // Crash prefix 1: the journal committed, no candidate was written and
      // the pointer never moved.
      let attempt1 = UUID()
      try await freshSecrets().write(
        try PiliAccountEnvelopeRecoveryJournal.encode(PiliAccountEnvelopeRecoveryJournal(
          attemptedTransactionID: attempt1,
          expectedPreviousTransactionID: baseline.transactionID,
          attemptedCandidateSHA256: String(repeating: "a", count: 64),
          kind: "credentials")),
        key: journalKey)
      let client1 = freshStore()
      guard let pending1 = try await client1.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("journal-only crash prefix lost across client reopen")
      }
      try check(pending1.attemptedTransactionID == attempt1 &&
        pending1.expectedPreviousTransactionID == baseline.transactionID,
        "a fresh client over the real Keychain reads the journal-only crash prefix")
      var fenced1 = false
      do {
        _ = try await client1.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("keychain-must-not-cross"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { fenced1 = true }
      try check(fenced1, "the reopened journal fence rejects an overwriting follower")
      guard let resolved1 = try await client1.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("journal-only crash prefix did not resolve")
      }
      try check(resolved1.outcome == .attemptNotCommitted &&
        resolved1.observedTransactionID == baseline.transactionID,
        "the journal-only crash prefix classifies not-committed by pointer identity")
      guard try await freshSecrets().read(journalKey) == nil else {
        throw QueueFixtureError.failed("journal-only crash prefix was not durably cleared")
      }
      guard case .record = try await client1.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("keychain-after-prefix1"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("keychain follower after prefix 1 expected")
      }
      guard let afterPrefix1 = try await client1.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing keychain snapshot after prefix 1")
      }
      try check(afterPrefix1.envelope.records[1].accessKeyUnits?.units ==
        Array("keychain-after-prefix1".utf16),
        "the reopened client publishes after the journal-only prefix is resolved")

      // Crash prefix 2: the journal committed and raw candidate bytes were
      // written, but the pointer never moved. Resolution must keep the retained
      // candidate bytes and publish the follower exactly once.
      let attempt2 = UUID()
      let recordKey2 = "account-envelope-shadow-v2.\(attempt2.uuidString.lowercased())"
      let secrets2 = freshSecrets()
      try await secrets2.write(
        try PiliAccountEnvelopeRecoveryJournal.encode(PiliAccountEnvelopeRecoveryJournal(
          attemptedTransactionID: attempt2,
          expectedPreviousTransactionID: afterPrefix1.transactionID,
          attemptedCandidateSHA256: String(repeating: "b", count: 64),
          kind: "credentials")),
        key: journalKey)
      try await secrets2.write(Data("retained-keychain-candidate".utf8), key: recordKey2)
      let client2 = freshStore()
      guard let pending2 = try await client2.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("journal+candidate crash prefix lost across client reopen")
      }
      try check(pending2.attemptedTransactionID == attempt2,
        "a fresh client reads the journal+candidate crash prefix")
      guard let resolved2 = try await client2.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("journal+candidate crash prefix did not resolve")
      }
      try check(resolved2.outcome == .attemptNotCommitted,
        "the journal+candidate crash prefix classifies not-committed")
      guard let retained2 = try await freshSecrets().read(recordKey2) else {
        throw QueueFixtureError.failed("resolution prematurely deleted the retained candidate")
      }
      try check(retained2 == Data("retained-keychain-candidate".utf8),
        "the retained candidate bytes survive resolution untouched")
      guard let pointerAfterPrefix2 = try await client2.loadShadowSnapshot(),
            pointerAfterPrefix2.transactionID == afterPrefix1.transactionID else {
        throw QueueFixtureError.failed("the journal+candidate prefix moved the pointer")
      }
      checks += 1
      guard case .record = try await client2.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("keychain-after-prefix2"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("keychain follower after prefix 2 expected")
      }

      // Crash prefix 3: the candidate committed (the pointer names the
      // attempted transaction) while the journal was left behind. Resolution
      // must prove the commit by exact identity and never replay the write.
      guard let beforePrefix3 = try await client2.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing keychain snapshot before prefix 3")
      }
      let publisherVault = PiliAccountEnvelopeStagingStore(secrets: freshSecrets())
      _ = try await publisherVault.importShadow(fx.codec.encode(beforePrefix3.envelope))
      guard let publisherSnapshot = try await publisherVault.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing raw keychain publication for prefix 3")
      }
      let attempt3 = publisherSnapshot.transactionID
      try await freshSecrets().write(
        try PiliAccountEnvelopeRecoveryJournal.encode(PiliAccountEnvelopeRecoveryJournal(
          attemptedTransactionID: attempt3,
          expectedPreviousTransactionID: beforePrefix3.transactionID,
          attemptedCandidateSHA256: String(repeating: "c", count: 64),
          kind: "credentials")),
        key: journalKey)
      let client3 = freshStore()
      guard let pending3 = try await client3.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("committed crash prefix lost across client reopen")
      }
      try check(pending3.attemptedTransactionID == attempt3 &&
        pending3.expectedPreviousTransactionID == beforePrefix3.transactionID,
        "a fresh client reads the committed-with-journal crash prefix")
      guard let resolved3 = try await client3.resolveUnresolvedPublication() else {
        throw QueueFixtureError.failed("committed crash prefix did not resolve")
      }
      try check(resolved3.outcome == .attemptCommitted &&
        resolved3.observedTransactionID == resolved3.attemptedTransactionID &&
        resolved3.attemptedTransactionID == attempt3,
        "the committed crash prefix classifies by exact operation identity")
      guard try await freshSecrets().read(journalKey) == nil else {
        throw QueueFixtureError.failed("committed crash prefix was not durably cleared")
      }
      guard let unchanged3 = try await client3.loadShadowSnapshot(),
            unchanged3.transactionID == attempt3 else {
        throw QueueFixtureError.failed("resolution replayed or moved the committed pointer")
      }
      checks += 1
      guard case .record = try await client3.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("keychain-after-prefix3"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("keychain follower after prefix 3 expected")
      }
      guard let afterPrefix3 = try await client3.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing keychain snapshot after prefix 3")
      }
      try check(afterPrefix3.transactionID != attempt3 &&
        afterPrefix3.envelope.records.count == 3 &&
        afterPrefix3.envelope.records[1].accessKeyUnits?.units ==
          Array("keychain-after-prefix3".utf16),
        "the reopened client publishes exactly one follower from the committed prefix")

      // Crash prefix 4: a foreign pointer committed while the journal named an
      // unresolved attempt. Startup must fence, classify explicitly ambiguous,
      // keep the journal and fence until an explicit acknowledgment, and never
      // replay or cover the foreign publication.
      guard let beforePrefix4 = try await client3.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing keychain snapshot before prefix 4")
      }
      _ = try await publisherVault.importShadow(fx.codec.encode(beforePrefix4.envelope))
      guard let foreignSnapshot = try await publisherVault.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing foreign keychain publication for prefix 4")
      }
      let attempt4 = UUID()
      try await freshSecrets().write(
        try PiliAccountEnvelopeRecoveryJournal.encode(PiliAccountEnvelopeRecoveryJournal(
          attemptedTransactionID: attempt4,
          expectedPreviousTransactionID: beforePrefix4.transactionID,
          attemptedCandidateSHA256: String(repeating: "d", count: 64),
          kind: "credentials")),
        key: journalKey)
      let client4 = freshStore()
      guard let pending4 = try await client4.loadPersistentRecovery() else {
        throw QueueFixtureError.failed("ambiguous crash prefix lost across client reopen")
      }
      try check(pending4.attemptedTransactionID == attempt4,
        "a fresh client reads the ambiguous-with-journal crash prefix")
      var fenced4 = false
      do {
        _ = try await client4.enqueue(.credentials(recordKey: fx.key,
          generation: fx.record.generation, accessKey: units("keychain-must-not-cover"),
          refreshToken: nil))
      } catch PiliAccountShadowTransactionError.unresolvedPublication { fenced4 = true }
      try check(fenced4, "the reopened ambiguous prefix fences an overwriting follower")
      var blocked4 = false
      do {
        _ = try await client4.resolveUnresolvedPublication()
      } catch PiliAccountShadowTransactionError.ambiguousRecovery { blocked4 = true }
      try check(blocked4,
        "the ambiguous prefix keeps its durable evidence until an explicit acknowledgment")
      guard try await freshSecrets().read(journalKey) != nil else {
        throw QueueFixtureError.failed("the default ambiguity resolution deleted the keychain journal")
      }
      try check(await client4.pendingUnresolvedPublication != nil,
        "the ambiguous prefix keeps the reopened fence")
      guard let acknowledged4 = try await client4.resolveUnresolvedPublication(allowAmbiguous: true) else {
        throw QueueFixtureError.failed("the ambiguous crash prefix left no acknowledged resolution")
      }
      try check(acknowledged4.outcome == .ambiguousObservedCandidate &&
        acknowledged4.observedTransactionID == foreignSnapshot.transactionID &&
        acknowledged4.attemptedTransactionID == attempt4 &&
        acknowledged4.expectedPreviousTransactionID == beforePrefix4.transactionID &&
        !acknowledged4.observedContentMatchesAttempt,
        "the acknowledged foreign candidate is ambiguous by identity, never claimed by content")
      guard try await freshSecrets().read(journalKey) == nil else {
        throw QueueFixtureError.failed("the acknowledged ambiguity did not clear the keychain journal")
      }
      guard let unchanged4 = try await client4.loadShadowSnapshot(),
            unchanged4.transactionID == foreignSnapshot.transactionID,
            unchanged4.envelope == beforePrefix4.envelope else {
        throw QueueFixtureError.failed("the ambiguity acknowledgment replayed or moved the foreign pointer")
      }
      checks += 1
      guard case .record = try await client4.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("keychain-after-prefix4"),
        refreshToken: nil)) else {
        throw QueueFixtureError.failed("keychain follower after prefix 4 expected")
      }
      guard let afterPrefix4 = try await client4.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing keychain snapshot after prefix 4")
      }
      try check(afterPrefix4.transactionID != foreignSnapshot.transactionID &&
        afterPrefix4.envelope.records[1].accessKeyUnits?.units ==
          Array("keychain-after-prefix4".utf16),
        "the reopened client publishes exactly one follower after the acknowledged ambiguity")
      try await publisherVault.discardShadow()
    } catch {
      try? await vault.discardShadow()
      throw error
    }
    return checks
  }

  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw QueueFixtureError.failed("fresh live actual Dart envelope golden required")
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]],
          let value = cases.first(where: {
            $0["id"] as? String == "stored-10-2-owner-2-10"
          })?["envelope"] else {
      throw QueueFixtureError.failed("actual Dart envelope missing")
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let codec = PiliAccountLiveMemoryShadowCodec()
    let base = try codec.decode(data)
    guard base.records.count == 3 else {
      throw QueueFixtureError.failed("expected anonymous + two login records")
    }
    let record = base.records[1]
    guard let key = record.storageKeyUnits, key.units == Array("10".utf16) else {
      throw QueueFixtureError.failed("expected raw storage key 10")
    }
    guard let key2 = base.records[2].storageKeyUnits else {
      throw QueueFixtureError.failed("missing second storage key")
    }
    let reducer = PiliNativeOrderedCookieReducer()
    let location = PiliOrderedCookieResponseLocation(host: "api.bilibili.com", path: "/x/test")
    let now: Int64 = 1_700_000_000_123_456
    let fields = ["txn-cookie=txn-value; Path=/; Domain=.bilibili.com"]
    let saved = try reducer.save(record.jar, fields: fields, representation: .separated,
                                 location: location, nowMicroseconds: now)
    let deleted = try reducer.delete(saved, host: "bilibili.com", withDomainSharedCookie: true)
    guard deleted.domainBuckets.isEmpty else {
      throw QueueFixtureError.failed("actual domain deletion fixture missing")
    }
    let cleared = try reducer.deleteAll(deleted)
    let fixture = QueueFixture(codec: codec, base: base, key: key, key2: key2,
      record: record, generation2: base.records[2].generation, cleared: cleared,
      fields: fields, location: location, now: now,
      save: PiliAccountShadowCookieSave(fields: fields, representation: .separated,
                                        location: location, nowMicroseconds: now))
    var checks = 0
    checks += try await checkIdentityReceipts(fixture)
    checks += try await checkQueuedKeychainWrites(fixture)
    checks += try await checkQueuedEffectReceipts(fixture)
    checks += try await checkQueuedFifoFaults(fixture)
    checks += try await checkUnknownFenceProtocol(fixture)
    checks += try await checkSameValueResolutionIdentity(fixture)
    checks += try await checkResolutionSerialization(fixture)
    checks += try await checkPersistentRecoveryJournal(fixture)
    checks += try await checkPersistentRecoveryKeychain(fixture)
    checks += try await checkQueueRetryExhaustion(fixture)
    checks += try await checkQueuedPurposeInterference(fixture)
    checks += try await checkQueueContention(fixture)
    checks += try await checkColdRecoveryContention(fixture)
    print("\(checks) native account envelope queue checks passed")
  }
}
