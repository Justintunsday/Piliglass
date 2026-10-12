import Foundation

private enum QueueFixtureError: Error { case failed(String), injected }

/// Secret store with pause/unknown fault injection for the queue contract.
private actor QueueFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable { case pointerWriteAfter, pointerReadAfter, pointerWriteBefore }
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
  private let pointer = "account-envelope-shadow-manifest-v2"

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
  func recordCount() -> Int {
    values.keys.filter { $0.hasPrefix("account-envelope-shadow-v2.") }.count
  }

  func read(_ key: String) async throws -> Data? {
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
    if pause {
      pause = false
      await withCheckedContinuation {
        suspended = $0
        pauseObserver?.resume()
        pauseObserver = nil
      }
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
  func remove(_ key: String) { values.removeValue(forKey: key) }
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

      // Cancellation while queued: no publication and the FIFO keeps draining.
      await fault.pauseWrite()
      let holder = Task { try await store.enqueue(.cookieDeleteAll(
        recordKey: fx.key, generation: fx.record.generation)) }
      await fault.waitUntilPaused()
      let cancelled = Task { try await store.enqueue(.credentials(recordKey: fx.key,
        generation: fx.record.generation, accessKey: units("queue-cancelled"),
        refreshToken: nil)) }
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
        "cancelled queued write leaves no effect and the queue keeps draining")

      // In-flight cancellation before the pointer write keeps the previous jar.
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

      // A queued resource-budget rejection releases the turn with no
      // publication and no fabricated receipt; a valid follower continues.
      guard let beforeBudget = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing pre-budget snapshot")
      }
      do {
        _ = try await store.enqueue(.buvidSeed(recordKey: fx.key,
          generation: fx.record.generation,
          value: PiliCookieUTF16(units: Array(repeating: 0x41,
            count: PiliAccountEnvelopeTransactionStore.buvidMaximumValueUnits + 1)),
          nowMicroseconds: fx.now))
        throw QueueFixtureError.failed("queued over-budget buvid accepted")
      } catch PiliAccountLiveMemoryShadowError.resourceLimit { checks += 1 }
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
      try check(await fault.recordCount() == 6,
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
      try check(unknownResolution.observedMatchedAttempt &&
        unknownResolution.observedTransactionID == unknownReadback.transactionID &&
        unknownResolution.attemptedCandidateSHA256 == unresolved.attemptedCandidateSHA256,
        "read-back resolution names the exact attempted candidate")
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
      try check(buvidResolution.observedMatchedAttempt,
                "the unknown buvid is resolved by exact candidate read-back")
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
      try await Task.sleep(nanoseconds: 150_000_000)
      await fenceFault.resume()
      _ = try await writeA.value
      _ = try await writeB.value
      try await waitForIdle(storeA)
      try await waitForIdle(storeB)
      let reloaded = try await PiliAccountEnvelopeStagingStore(secrets: fenceFault).loadShadow()
      try check(reloaded?.records[1].accessKeyUnits?.units == Array("store-a".utf16) &&
        reloaded?.records[2].jar == fx.cleared,
        "cross-store queued writes serialize through the shared vault without lost updates")
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
      try check(!beforeResolution.observedMatchedAttempt &&
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
      try check(afterResolution.observedMatchedAttempt &&
        afterResolution.observedTransactionID != afterRetry.transactionID,
        "the write-after-error resolution names the committed attempted candidate")
      guard let durableAfter = try await store.loadShadowSnapshot() else {
        throw QueueFixtureError.failed("missing post-resolution snapshot")
      }
      try check(durableAfter.envelope.records[1].accessKeyUnits?.units ==
        Array("unknown-after".utf16),
        "the committed unknown write is durable exactly once, without replay")

      // Reopen boundary: the in-process fence stays fail-closed on the old
      // store; a fresh store over the same secrets reads the committed
      // candidate before its own CAS publish and never replays the unknown.
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
    checks += try await checkQueueRetryExhaustion(fixture)
    checks += try await checkQueuedPurposeInterference(fixture)
    checks += try await checkQueueContention(fixture)
    print("\(checks) native account envelope queue checks passed")
  }
}
