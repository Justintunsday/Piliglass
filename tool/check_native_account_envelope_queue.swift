import Foundation

private enum QueueFixtureError: Error { case failed(String), injected }

/// Secret store with pause/unknown fault injection for the queue contract.
private actor QueueFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable { case pointerWriteAfter, pointerReadAfter }
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

  /// Fault-vault queue semantics: bounded FIFO order, overflow, queued and
  /// in-flight cancellation, and unknown publications that are resolved by
  /// read-back instead of replay.
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
      _ = try await store.enqueue(.adoptIdentities)

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
      let reloaded = try await PiliAccountEnvelopeStagingStore(secrets: fault).loadShadow()
      try check(reloaded?.records[1].accessKeyUnits?.units == Array("queue-c".utf16),
                "final queued credentials keep submission order")
      try check(reloaded?.records[1].jar == fx.cleared,
                "final queued deleteAll survives the later credentials write")
      let pendingAfterDrain = await store.pendingWriteCount
      let idleAfterDrain = await store.writeQueueIdle
      try check(pendingAfterDrain == 0 && idleAfterDrain,
                "the FIFO releases every turn after draining")
      let publishedRecords = await fault.recordCount()
      try check(publishedRecords == 5,
                "the queue publishes exactly one record per admitted write")
      let middle = try await vault.loadPublishedCandidate(transactionID: receiptB.transactionID)
      try check(middle.records[1].accessKeyUnits?.units == Array("queue-a".utf16) &&
        middle.records[1].jar == fx.cleared,
        "the middle queued write built on the previous publication")

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

      // Unknown install: surfaced, durable once, next queued write continues,
      // and a naive replay is rejected instead of reapplying.
      await fault.arm(.pointerReadAfter)
      let unknownInstall = PiliAccountShadowInstall(storageKeyUnits: units("queue-unknown"),
        mid: 99, generation: fx.record.generation + 900, accessKeyUnits: nil,
        refreshTokenUnits: nil, persistedPurposes: [], activated: false, jar: fx.cleared)
      let unknownA = Task { try await store.enqueue(.install(unknownInstall)) }
      let unknownB = Task { try await store.enqueue(.cookieSave(
        recordKey: fx.key, generation: fx.record.generation, save: fx.save)) }
      var unknownSurfaced = false
      do {
        _ = try await unknownA.value
        throw QueueFixtureError.failed("unknown publication fabricated a receipt")
      } catch PiliAccountEnvelopeStagingError.publicationUnknown { unknownSurfaced = true }
      try check(unknownSurfaced,
                "queued unknown publication propagates instead of a fake receipt")
      guard case .record = try await unknownB.value else {
        throw QueueFixtureError.failed("follower after unknown expected")
      }
      try await waitForIdle(store)
      let afterUnknown = try await store.loadShadowSnapshot()
      try check(afterUnknown?.envelope.records.count == 4 &&
        afterUnknown?.envelope.records[3].storageKeyUnits == units("queue-unknown") &&
        afterUnknown?.envelope.records[1].jar != fx.cleared,
        "the unknown publication is durable once and the queue continues from read-back truth")
      do {
        _ = try await store.enqueue(.install(unknownInstall))
        throw QueueFixtureError.failed("unknown install replay accepted")
      } catch PiliAccountShadowTransactionError.duplicateRecordKey { checks += 1 }

      // Unknown buvid: read-back resolves the durable seed; the correct retry is
      // an idempotent no-op, never a blind replay.
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
      try check(buvidPresent && !buvidRetry.seeded && buvidRetry.transactionID == nil,
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
    checks += try await checkQueuedFifoFaults(fixture)
    checks += try await checkQueueContention(fixture)
    print("\(checks) native account envelope queue checks passed")
  }
}
