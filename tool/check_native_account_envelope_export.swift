import CryptoKit
import Foundation

private enum ExportFixtureError: Error { case failed(String), injected }

/// Fault-injecting secret store for the atomic export contract. Every read,
/// write and remove ATTEMPT is counted, so the export rows can prove zero
/// attempted durable mutations and pre-cancel zero IO. Reads can be paused at
/// the journal/manifest/record stage, failed, cancelled deterministically or
/// made to throw an unrelated typed error; the pointer acknowledgment read can
/// be made unreadable so a real correlated publication yields an actual
/// unknown. The controlled-await helper reports EVERY terminal task outcome
/// (first-write-wins) so an early success or failure is surfaced instead of
/// waiting forever. Fixture setup installs bytes directly without counting them
/// as export attempts.
private actor ExportFaultVault: PiliAccountSecretStore {
  private let pointerKey = "account-envelope-shadow-manifest-v2"
  private let recoveryJournalKey = "account-envelope-recovery-journal-v1"
  private var values: [String: Data] = [:]
  private var readAttempts = 0
  private var writeAttempts = 0
  private var removeAttempts = 0
  private var pauseJournalRead = false
  private var journalReadSuspended: CheckedContinuation<Void, Never>?
  private var pauseManifestRead = false
  private var manifestReadSuspended: CheckedContinuation<Void, Never>?
  private var pauseRecordRead = false
  private var recordReadSuspended: CheckedContinuation<Void, Never>?
  private var journalReadFails = false
  private var journalReadTypedError = false
  private var journalReadCancels = false
  private var pointerReadFailures = 0
  private var pointerReadFailSkip = 0
  private var exportTerminal: String?
  private var phaseWaiters: [CheckedContinuation<Void, Never>] = []

  func readAttemptCount() -> Int { readAttempts }
  func writeAttemptCount() -> Int { writeAttempts }
  func removeAttemptCount() -> Int { removeAttempts }
  func storedBytes(_ key: String) -> Data? { values[key] }
  func storedSnapshot() -> [String: Data] { values }
  func installFixtureBytes(_ data: Data, key: String) { values[key] = data }
  func rawRemove(_ key: String) { values.removeValue(forKey: key) }
  func resetExportCounters() {
    readAttempts = 0
    writeAttempts = 0
    removeAttempts = 0
  }
  func failJournalReads(_ enabled: Bool) { journalReadFails = enabled }
  func failJournalReadsTyped(_ enabled: Bool) { journalReadTypedError = enabled }
  func cancelJournalReads(_ enabled: Bool) { journalReadCancels = enabled }
  func pauseJournalReadOnce() { pauseJournalRead = true }
  func resumeJournalRead() {
    journalReadSuspended?.resume()
    journalReadSuspended = nil
  }
  func pauseManifestReadOnce() { pauseManifestRead = true }
  func resumeManifestRead() {
    manifestReadSuspended?.resume()
    manifestReadSuspended = nil
  }
  func pauseRecordReadOnce() { pauseRecordRead = true }
  func resumeRecordRead() {
    recordReadSuspended?.resume()
    recordReadSuspended = nil
  }
  /// Fails the pointer read that follows `skip` further successful pointer
  /// reads. A correlated publication reads the pointer for its snapshot/CAS
  /// pre-check and then once more for the acknowledgment, so skip 2 targets
  /// exactly the unreadable-ack boundary.
  func failPointerReadsAfter(_ skip: Int) {
    pointerReadFailSkip = skip
    pointerReadFailures = 1
  }
  func allowPointerReads() {
    pointerReadFailSkip = 0
    pointerReadFailures = 0
  }
  /// Terminal reporting is first-write-wins: a task outcome is never rewritten
  /// by cleanup. Waiting for a controlled phase returns as soon as the task
  /// reports success/failure, so an early terminal result never hangs.
  func noteExportTerminal(_ outcome: String) {
    if exportTerminal == nil { exportTerminal = outcome }
    let waiters = phaseWaiters
    phaseWaiters = []
    for waiter in waiters { waiter.resume() }
  }
  func terminalOutcome() -> String? { exportTerminal }
  func waitUntilPhaseOrTerminal() async -> Bool {
    if journalReadSuspended != nil || manifestReadSuspended != nil || recordReadSuspended != nil {
      return true
    }
    if exportTerminal != nil { return false }
    await withCheckedContinuation { phaseWaiters.append($0) }
    return journalReadSuspended != nil || manifestReadSuspended != nil || recordReadSuspended != nil
  }

  func read(_ key: String) async throws -> Data? {
    readAttempts += 1
    if key == recoveryJournalKey {
      if journalReadCancels { throw CancellationError() }
      if journalReadTypedError { throw PiliAccountEnvelopeStagingError.missingRecord }
      if journalReadFails { throw ExportFixtureError.injected }
      if pauseJournalRead {
        pauseJournalRead = false
        await withCheckedContinuation {
          journalReadSuspended = $0
          let waiters = phaseWaiters
          phaseWaiters = []
          for waiter in waiters { waiter.resume() }
        }
      }
      return values[key]
    }
    if key == pointerKey {
      if pauseManifestRead {
        pauseManifestRead = false
        await withCheckedContinuation {
          manifestReadSuspended = $0
          let waiters = phaseWaiters
          phaseWaiters = []
          for waiter in waiters { waiter.resume() }
        }
      }
      if pointerReadFailures > 0 {
        if pointerReadFailSkip > 0 {
          pointerReadFailSkip -= 1
        } else {
          if pointerReadFailures != Int.max { pointerReadFailures -= 1 }
          throw ExportFixtureError.injected
        }
      }
      return values[key]
    }
    if key.hasPrefix("account-envelope-shadow-v2.") {
      if pauseRecordRead {
        pauseRecordRead = false
        await withCheckedContinuation {
          recordReadSuspended = $0
          let waiters = phaseWaiters
          phaseWaiters = []
          for waiter in waiters { waiter.resume() }
        }
      }
      return values[key]
    }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    writeAttempts += 1
    values[key] = data
  }

  func remove(_ key: String) async throws {
    removeAttempts += 1
    values.removeValue(forKey: key)
  }
}

@main private struct AccountEnvelopeExportChecks {
  private static let manifestKey = "account-envelope-shadow-manifest-v2"
  private static let journalKey = "account-envelope-recovery-journal-v1"
  private static let fixtureCaseID = "stored-10-2-owner-2-10"
  private static let exportKind = "export-qa"

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func require(_ condition: Bool, _ label: String) throws {
    guard condition else { throw ExportFixtureError.failed(label) }
  }

  private static func recordKey(_ id: UUID) -> String {
    "account-envelope-shadow-v2.\(id.uuidString.lowercased())"
  }

  private static func makeJournal(_ fill: String) throws -> Data {
    let journal = PiliAccountEnvelopeRecoveryJournal(
      attemptedTransactionID: UUID(), expectedPreviousTransactionID: nil,
      attemptedCandidateSHA256: String(repeating: fill, count: 64), kind: exportKind)
    return try PiliAccountEnvelopeRecoveryJournal.encode(journal)
  }

  private static func manifestBytes(transactionID: UUID, byteCount: Int, sha256: String) throws -> Data {
    let object: [String: Any] = [
      "schemaVersion": 2,
      "transactionID": transactionID.uuidString.lowercased(),
      "byteCount": byteCount,
      "sha256": sha256,
    ]
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func remintedManifest(_ bytes: Data) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw ExportFixtureError.failed("manifest JSON expected")
    }
    object["transactionID"] = UUID().uuidString.lowercased()
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  /// A schema-3-shaped envelope whose records array exceeds the codec's strict
  /// 256-record ceiling: the digest and byte count are made consistent with the
  /// manifest, so only the production codec's resource limit can reject it.
  private static func resourceLimitedEnvelope(codec: PiliAccountLiveMemoryShadowCodec,
                                              base: PiliAccountLiveMemoryShadow) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: codec.encode(base)) as? [String: Any],
          var records = object["records"] as? [[String: Any]],
          let sample = records.dropFirst().first else {
      throw ExportFixtureError.failed("schema-2 records expected")
    }
    let highWater = records.dropFirst().compactMap { $0["generation"] as? Int }.max() ?? 0
    object["schemaVersion"] = 3
    object["generationHighWater"] = highWater
    while records.count < 257 {
      records.append(sample)
    }
    object["records"] = records
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func makeAdoptedVault(
    codec: PiliAccountLiveMemoryShadowCodec, base: PiliAccountLiveMemoryShadow
  ) async throws -> (ExportFaultVault, PiliAccountEnvelopeStagingStore,
                     PiliAccountEnvelopeTransactionStore, PiliAccountEnvelopeSnapshot) {
    let vault = ExportFaultVault()
    let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
    let store = PiliAccountEnvelopeTransactionStore(vault: staging)
    try await staging.importShadow(codec.encode(base))
    _ = try await store.adoptMissingIdentities()
    guard let current = try await staging.loadShadowSnapshot() else {
      throw ExportFixtureError.failed("missing adopted shadow")
    }
    return (vault, staging, store, current)
  }

  private static func startExportTask(
    vault: ExportFaultVault, staging: PiliAccountEnvelopeStagingStore,
    expectedTransactionID: UUID
  ) -> Task<PiliAccountEnvelopeExport, any Error> {
    Task {
      do {
        let value = try await staging.exportCurrentShadow(expectedTransactionID: expectedTransactionID)
        await vault.noteExportTerminal("success")
        return value
      } catch {
        await vault.noteExportTerminal("failure")
        throw error
      }
    }
  }

  /// Controlled-await driver: waits for the injected phase or an early terminal
  /// result, runs the between-step (a legitimate writer attempt or a fixture
  /// mutation), cancels when requested, and ALWAYS resumes and awaits the task
  /// on every path so nothing stays suspended behind a failed assertion.
  private static func runControlledExport(
    label: String, vault: ExportFaultVault, staging: PiliAccountEnvelopeStagingStore,
    expectedTransactionID: UUID, cancelBeforeResume: Bool,
    between: () async throws -> Int
  ) async throws -> (value: PiliAccountEnvelopeExport, checks: Int) {
    let task = startExportTask(vault: vault, staging: staging,
                               expectedTransactionID: expectedTransactionID)
    do {
      let paused = await vault.waitUntilPhaseOrTerminal()
      try require(paused, "\(label): export reached a terminal result before the controlled await")
      let betweenChecks = try await between()
      if cancelBeforeResume {
        task.cancel()
      }
      await vault.resumeJournalRead()
      await vault.resumeManifestRead()
      await vault.resumeRecordRead()
      let value = try await task.value
      return (value, betweenChecks)
    } catch {
      task.cancel()
      await vault.resumeJournalRead()
      await vault.resumeManifestRead()
      await vault.resumeRecordRead()
      _ = try? await task.value
      await vault.noteExportTerminal("failure")
      throw error
    }
  }

  /// Rows 1-6 of the proof matrix: byte-exact zero-attempt success, absent and
  /// schema-2 refusals, stale/historical-pointer refusals with a full winner
  /// oracle, and persistent journal evidence failing the export closed.
  private static func checkFaultVaultBasics(codec: PiliAccountLiveMemoryShadowCodec,
                                            base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      try require(current.envelope.schemaVersion == 3, "adoption publishes schema 3")
      checks += 1
      guard let storedRecord = await vault.storedBytes(recordKey(current.transactionID)) else {
        throw ExportFixtureError.failed("missing stored record bytes")
      }
      let storedPointer = await vault.storedBytes(manifestKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      let export = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(export.transactionID == current.transactionID, "export keeps the pinned pointer")
      checks += 1
      try require(export.envelopeBytes == storedRecord, "export returns the exact stored bytes")
      checks += 1
      try require(export.envelopeSHA256 == sha256Hex(storedRecord), "export digest matches the stored bytes")
      checks += 1
      let decoded = try codec.decode(export.envelopeBytes)
      try require(decoded.schemaVersion == 3, "exported bytes strictly decode as schema 3")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0,
                  "successful export attempts zero durable writes/removes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "successful export changes no vault byte")
      checks += 1
      let journalAfter = await vault.storedBytes(journalKey)
      let pointerAfter = snapshotAfter[manifestKey]
      try require(journalAfter == nil && pointerAfter == storedPointer,
                  "no recovery journal appears and the pointer byte is intact")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let snapshotBefore = await vault.storedSnapshot()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.shadowUnavailable { surfaced = true }
      try require(surfaced, "absent pointer exports shadowUnavailable")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "absent-pointer refusal is zero-write")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "absent-pointer refusal preserves every vault byte")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      try await staging.importShadow(codec.encode(base))
      guard let snapshot = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing schema-2 publication")
      }
      let pointerBefore = await vault.storedBytes(manifestKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: snapshot.transactionID) }
      catch PiliAccountEnvelopeStagingError.shadowUnavailable { surfaced = true }
      try require(surfaced, "schema-2 publication is not an exportable schema-3 shadow")
      checks += 1
      let pointerAfter = await vault.storedBytes(manifestKey)
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(pointerAfter == pointerBefore && writeAttempts == 0 && removeAttempts == 0,
                  "schema-2 refusal preserves the pointer with zero writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "schema-2 refusal preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, first) = try await makeAdoptedVault(codec: codec, base: base)
      try await staging.importShadow(codec.encode(base))
      guard let second = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing second publication")
      }
      try require(second.transactionID != first.transactionID, "raw follow-up moves the pointer")
      checks += 1
      let historical = try await staging.loadPublishedCandidate(transactionID: first.transactionID)
      try require(historical.schemaVersion == 3, "historical adopted candidate stays readable")
      checks += 1
      let snapshotBefore = await vault.storedSnapshot()
      let winnerRecordBefore = await vault.storedBytes(recordKey(second.transactionID))
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: first.transactionID) }
      catch PiliAccountEnvelopeStagingError.staleExport { surfaced = true }
      try require(surfaced, "historical candidate is never substituted for the current pointer")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "stale refusal attempts no writes")
      checks += 1
      // Full winner oracle: the complete envelope and the exact record bytes,
      // not only the transaction ID.
      try require(second.envelope == base, "full winner envelope equals the independent raw publication")
      checks += 1
      try require(winnerRecordBefore == codec.encode(base),
                  "winner record bytes equal the independently encoded publication")
      checks += 1
      let journalAfter = await vault.storedBytes(journalKey)
      try require(journalAfter == nil, "stale refusal leaves no journal")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "stale refusal preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      // Synthetic fixture evidence: the journal bytes are installed directly,
      // not produced by a store publication (the real store-B unknown path is
      // covered separately).
      let journalBytes = try makeJournal("a")
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "persistent journal fails the export closed")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "journal refusal attempts no writes")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "journal bytes are preserved exactly")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "journal refusal preserves every vault byte")
      checks += 1
    }
    return checks
  }

  /// The export must read persistent journal evidence fresh and classify it by
  /// exact type: a transaction store's cached clean state cannot hide a journal
  /// that appears afterwards; corrupt bytes stay invalidRecoveryJournal; an
  /// unrelated typed read error never leaks and fails closed as
  /// unresolvedRecovery.
  private static func checkFreshAndInvalidJournal(codec: PiliAccountLiveMemoryShadowCodec,
                                                  base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let (vault, staging, store, current) = try await makeAdoptedVault(codec: codec, base: base)
      let cached = try await store.loadPersistentRecovery()
      try require(cached == nil, "transaction store carries a cached clean recovery state")
      checks += 1
      let journalBytes = try makeJournal("b")
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "export reads journal evidence fresh, not from the cached store")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "cached-clean refusal attempts no writes")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "fresh journal bytes are preserved")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "cached-clean refusal preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      let corrupt = Data("not-a-canonical-journal".utf8)
      await vault.installFixtureBytes(corrupt, key: journalKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.invalidRecoveryJournal { surfaced = true }
      try require(surfaced, "corrupt journal surfaces invalidRecoveryJournal")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == corrupt, "corrupt journal bytes are preserved")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "corrupt-journal refusal is zero-write")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "corrupt-journal refusal preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      let journalBytes = try makeJournal("c")
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      await vault.failJournalReads(true)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      await vault.failJournalReads(false)
      try require(surfaced, "unreadable journal fails closed as unresolvedRecovery")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "unreadable journal bytes are preserved")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "unreadable-journal refusal is zero-write")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "unreadable-journal refusal preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      await vault.failJournalReadsTyped(true)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      await vault.failJournalReadsTyped(false)
      try require(surfaced, "unrelated typed journal read error fails closed as unresolvedRecovery")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "typed journal error attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "typed journal error preserves every vault byte")
      checks += 1
    }
    return checks
  }

  /// Export-specific negative rows: corrupted manifest, missing record, count
  /// and digest mismatches, a digest-consistent but non-decoding record, a
  /// digest-consistent schema-2 envelope and a digest-consistent envelope over
  /// the strict codec resource ceiling. Every row proves zero attempted
  /// writes/removes and byte-exact preservation.
  private static func checkExportNegatives(codec: PiliAccountLiveMemoryShadowCodec,
                                           base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let (vault, staging, _, _) = try await makeAdoptedVault(codec: codec, base: base)
      await vault.installFixtureBytes(Data("not-a-manifest".utf8), key: manifestKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.invalidManifest { surfaced = true }
      try require(surfaced, "corrupt manifest surfaces invalidManifest")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "corrupt manifest attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "corrupt manifest is preserved byte-exactly")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      await vault.rawRemove(recordKey(current.transactionID))
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.missingRecord { surfaced = true }
      try require(surfaced, "missing record surfaces missingRecord")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "missing record attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "missing record preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      await vault.installFixtureBytes(Data(repeating: 0, count: 3), key: recordKey(current.transactionID))
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.verificationFailed { surfaced = true }
      try require(surfaced, "record count mismatch surfaces verificationFailed")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "count mismatch attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "count mismatch preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      guard var storedRecord = await vault.storedBytes(recordKey(current.transactionID)),
            let lastIndex = storedRecord.indices.last else {
        throw ExportFixtureError.failed("missing record for digest tamper")
      }
      storedRecord[lastIndex] ^= 0x01
      await vault.installFixtureBytes(storedRecord, key: recordKey(current.transactionID))
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.verificationFailed { surfaced = true }
      try require(surfaced, "same-length digest mismatch surfaces verificationFailed")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "digest mismatch attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "digest mismatch preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, _) = try await makeAdoptedVault(codec: codec, base: base)
      let pointer = UUID()
      let schemaTwoBytes = try codec.encode(base)
      let manifest = try manifestBytes(transactionID: pointer, byteCount: schemaTwoBytes.count,
                                       sha256: sha256Hex(schemaTwoBytes))
      await vault.installFixtureBytes(schemaTwoBytes, key: recordKey(pointer))
      await vault.installFixtureBytes(manifest, key: manifestKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: pointer) }
      catch PiliAccountEnvelopeStagingError.shadowUnavailable { surfaced = true }
      try require(surfaced, "digest-consistent schema-2 record is not exportable")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "schema-2 digest-consistent row attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "schema-2 digest-consistent row preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, _) = try await makeAdoptedVault(codec: codec, base: base)
      let pointer = UUID()
      let resourceBytes = try resourceLimitedEnvelope(codec: codec, base: base)
      let manifest = try manifestBytes(transactionID: pointer, byteCount: resourceBytes.count,
                                       sha256: sha256Hex(resourceBytes))
      await vault.installFixtureBytes(resourceBytes, key: recordKey(pointer))
      await vault.installFixtureBytes(manifest, key: manifestKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: pointer) }
      catch PiliAccountEnvelopeStagingError.verificationFailed { surfaced = true }
      try require(surfaced, "digest-consistent resource-limit envelope is refused")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "resource-limit envelope attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "resource-limit envelope preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, _) = try await makeAdoptedVault(codec: codec, base: base)
      let pointer = UUID()
      let invalidBytes = Data("not-a-json-record".utf8)
      let manifest = try manifestBytes(transactionID: pointer, byteCount: invalidBytes.count,
                                       sha256: sha256Hex(invalidBytes))
      await vault.installFixtureBytes(invalidBytes, key: recordKey(pointer))
      await vault.installFixtureBytes(manifest, key: manifestKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: pointer) }
      catch PiliAccountEnvelopeStagingError.verificationFailed { surfaced = true }
      try require(surfaced, "digest-consistent undecodable record is refused")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "undecodable record attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "undecodable record preserves every vault byte")
      checks += 1
    }
    return checks
  }

  /// Real same-vault unknown path: store A loads a cached clean recovery state,
  /// the read-only export succeeds before the unknown, then store B on the SAME
  /// shared vault performs a real correlated publication whose pointer
  /// acknowledgment is unreadable. The actual `publicationUnknown` retains the
  /// durable journal and B's in-memory fence; the read-only export then rejects
  /// while preserving every persistent byte with zero attempted writes and no
  /// resolve/clear/replay.
  private static func checkStoreBUnknown(codec: PiliAccountLiveMemoryShadowCodec,
                                         base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let (vault, staging, storeA, current) = try await makeAdoptedVault(codec: codec, base: base)
    guard let key = base.records[1].storageKeyUnits else {
      throw ExportFixtureError.failed("missing login key")
    }
    let cachedA = try await storeA.loadPersistentRecovery()
    try require(cachedA == nil, "store A loaded a cached clean recovery state")
    checks += 1
    await vault.resetExportCounters()
    let before = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
    let beforeWrites = await vault.writeAttemptCount()
    let beforeRemoves = await vault.removeAttemptCount()
    try require(before.transactionID == current.transactionID, "clean export precedes the unknown write")
    checks += 1
    try require(beforeWrites == 0 && beforeRemoves == 0, "clean export attempts zero mutations")
    checks += 1
    let storeB = PiliAccountEnvelopeTransactionStore(vault: staging)
    await vault.failPointerReadsAfter(2)
    var unknownSurfaced = false
    do {
      _ = try await storeB.applyTemporarySelection(
        recordKeyUnits: key, expectedGeneration: base.records[1].generation, purpose: .video)
    } catch PiliAccountEnvelopeStagingError.publicationUnknown {
      unknownSurfaced = true
    }
    await vault.allowPointerReads()
    try require(unknownSurfaced, "store B surfaces the real correlated publicationUnknown")
    checks += 1
    let journalAfterUnknown = await vault.storedBytes(journalKey)
    try require(journalAfterUnknown != nil, "the unknown acknowledgment retains the durable journal")
    checks += 1
    let pendingB = try await storeB.loadPersistentRecovery()
    try require(pendingB != nil, "store B keeps its in-memory armed fence")
    checks += 1
    let staleCachedA = try await storeA.loadPersistentRecovery()
    try require(staleCachedA == nil, "store A's cached clean view cannot see the new evidence")
    checks += 1
    let snapshotBefore = await vault.storedSnapshot()
    await vault.resetExportCounters()
    var rejected = false
    do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
    catch PiliAccountEnvelopeStagingError.unresolvedRecovery { rejected = true }
    try require(rejected, "read-only export rejects the real store-B unknown")
    checks += 1
    let writeAttempts = await vault.writeAttemptCount()
    let removeAttempts = await vault.removeAttemptCount()
    try require(writeAttempts == 0 && removeAttempts == 0, "unknown refusal attempts no writes")
    checks += 1
    let snapshotAfter = await vault.storedSnapshot()
    try require(snapshotAfter == snapshotBefore, "unknown refusal preserves every persistent byte")
    checks += 1
    let journalPreserved = await vault.storedBytes(journalKey)
    try require(journalPreserved == journalAfterUnknown, "journal bytes are never resolved or cleared")
    checks += 1
    return checks
  }

  /// A same-vault legitimate writer must meet the export's operation fence while
  /// the export is paused after its journal read; the winner and the export are
  /// preserved, and after release a new publication makes the old pointer stale.
  private static func checkSameVaultContention(codec: PiliAccountLiveMemoryShadowCodec,
                                               base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
    let pointerBefore = await vault.storedBytes(manifestKey)
    await vault.resetExportCounters()
    await vault.pauseManifestReadOnce()
    let export = try await runControlledExport(
      label: "contention", vault: vault, staging: staging,
      expectedTransactionID: current.transactionID, cancelBeforeResume: false
    ) {
      var rejected = false
      do { _ = try await staging.importShadow(codec.encode(base)) }
      catch PiliAccountEnvelopeStagingError.operationInProgress { rejected = true }
      try require(rejected, "same-vault writer meets the export operation fence")
      let pointerDuring = await vault.storedBytes(manifestKey)
      try require(pointerDuring == pointerBefore, "rejected writer leaves the winner untouched")
      return 2
    }
    checks += export.checks
    try require(export.value.transactionID == current.transactionID,
                "paused export resumes on the pinned pointer")
    checks += 1
    let writeAttempts = await vault.writeAttemptCount()
    let removeAttempts = await vault.removeAttemptCount()
    try require(writeAttempts == 0 && removeAttempts == 0, "contended export attempts zero mutations")
    checks += 1
    try await staging.importShadow(codec.encode(base))
    guard let moved = try await staging.loadShadowSnapshot() else {
      throw ExportFixtureError.failed("missing post-release publication")
    }
    try require(moved.transactionID != current.transactionID, "post-release publication moves the pointer")
    checks += 1
    var stale = false
    do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
    catch PiliAccountEnvelopeStagingError.staleExport { stale = true }
    try require(stale, "post-release move makes the old expectation stale")
    checks += 1
    return checks
  }

  /// Cancellation semantics: a pre-cancelled task performs zero IO; cancelling
  /// while a read is paused and explicitly resuming surfaces the exact
  /// CancellationError instead of the resumed result's typed outcome (nil
  /// manifest, changed manifest, nil record, corrupt record); unrelated typed
  /// journal errors never leak. Every path preserves persistent bytes, attempts
  /// no writes/removes and releases the fence for a later valid operation.
  private static func checkCancellationAtAwaits(codec: PiliAccountLiveMemoryShadowCodec,
                                                base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      let task = Task<PiliAccountEnvelopeExport, any Error> {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      }
      var cancelled = false
      do { _ = try await task.value } catch is CancellationError { cancelled = true }
      try require(cancelled, "pre-cancelled task throws CancellationError before any IO")
      checks += 1
      let reads = await vault.readAttemptCount()
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(reads == 0 && writeAttempts == 0 && removeAttempts == 0,
                  "pre-cancel performs zero vault IO")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "pre-cancel preserves every vault byte")
      checks += 1
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID, "fence released after pre-cancel")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      // Synthetic journal fixture: the read is paused and the task cancelled
      // before the present journal could be reported as unresolvedRecovery.
      let journalBytes = try makeJournal("d")
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetExportCounters()
      await vault.pauseJournalReadOnce()
      var cancelled = false
      do {
        _ = try await runControlledExport(
          label: "journal-present-cancel", vault: vault, staging: staging,
          expectedTransactionID: current.transactionID, cancelBeforeResume: true) { 0 }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "journal present + cancel across the read stays CancellationError")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "journal cancel attempts no writes")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "journal bytes survive the cancelled read")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "journal cancel preserves every vault byte")
      checks += 1
      await vault.rawRemove(journalKey)
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID, "fence released after journal cancel")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      guard let manifestBefore = await vault.storedBytes(manifestKey) else {
        throw ExportFixtureError.failed("missing manifest bytes")
      }
      await vault.resetExportCounters()
      await vault.pauseManifestReadOnce()
      var cancelled = false
      do {
        _ = try await runControlledExport(
          label: "manifest-nil-cancel", vault: vault, staging: staging,
          expectedTransactionID: current.transactionID, cancelBeforeResume: true) {
          await vault.rawRemove(manifestKey)
          return 0
        }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "cancelled nil manifest is CancellationError, not shadowUnavailable")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "nil-manifest cancel attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter[manifestKey] == nil, "the resumed nil manifest stays as observed")
      checks += 1
      await vault.installFixtureBytes(manifestBefore, key: manifestKey)
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID, "fence released after nil-manifest cancel")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      guard let manifestBefore = await vault.storedBytes(manifestKey),
            let recordBefore = await vault.storedBytes(recordKey(current.transactionID)) else {
        throw ExportFixtureError.failed("missing manifest/record bytes")
      }
      // An orphaned changed pointer: the manifest is reminted to a fresh
      // transaction ID with NO record under that key. The independent expected
      // vault state is the original fixture with exactly that one manifest
      // replacement; the ORIGINAL complete fixture is restored before any valid
      // cleanup read or export, and no unexpected error is swallowed.
      let moved = try remintedManifest(manifestBefore)
      let originalSnapshot = await vault.storedSnapshot()
      var expectedMutated = originalSnapshot
      expectedMutated[manifestKey] = moved
      await vault.resetExportCounters()
      await vault.pauseManifestReadOnce()
      var cancelled = false
      do {
        _ = try await runControlledExport(
          label: "manifest-changed-cancel", vault: vault, staging: staging,
          expectedTransactionID: current.transactionID, cancelBeforeResume: true) {
          await vault.installFixtureBytes(moved, key: manifestKey)
          return 0
        }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "cancelled changed manifest is CancellationError, not staleExport")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "changed-manifest cancel attempts no writes")
      checks += 1
      let mutated = await vault.storedSnapshot()
      try require(mutated == expectedMutated,
                  "changed-manifest cancel preserves the exact independently expected fixture mutation")
      checks += 1
      await vault.installFixtureBytes(manifestBefore, key: manifestKey)
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID &&
                  cleanup.envelopeBytes == recordBefore &&
                  cleanup.envelopeSHA256 == sha256Hex(recordBefore),
                  "cleanup export returns the original pointer bytes and digest")
      checks += 1
      let after = await vault.storedSnapshot()
      try require(after == originalSnapshot, "cleanup restores the original vault bytes")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      guard let recordBefore = await vault.storedBytes(recordKey(current.transactionID)) else {
        throw ExportFixtureError.failed("missing record bytes")
      }
      await vault.resetExportCounters()
      await vault.pauseRecordReadOnce()
      var cancelled = false
      do {
        _ = try await runControlledExport(
          label: "record-nil-cancel", vault: vault, staging: staging,
          expectedTransactionID: current.transactionID, cancelBeforeResume: true) {
          await vault.rawRemove(recordKey(current.transactionID))
          return 0
        }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "cancelled nil record is CancellationError, not missingRecord")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "nil-record cancel attempts no writes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter[recordKey(current.transactionID)] == nil,
                  "the resumed nil record stays as observed")
      checks += 1
      await vault.installFixtureBytes(recordBefore, key: recordKey(current.transactionID))
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID, "fence released after nil-record cancel")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      guard let recordBefore = await vault.storedBytes(recordKey(current.transactionID)) else {
        throw ExportFixtureError.failed("missing record bytes")
      }
      let corrupt = Data("corrupt-record-bytes".utf8)
      await vault.resetExportCounters()
      await vault.pauseRecordReadOnce()
      var cancelled = false
      do {
        _ = try await runControlledExport(
          label: "record-corrupt-cancel", vault: vault, staging: staging,
          expectedTransactionID: current.transactionID, cancelBeforeResume: true) {
          await vault.installFixtureBytes(corrupt, key: recordKey(current.transactionID))
          return 0
        }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "cancelled corrupt record is CancellationError, not verificationFailed")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "corrupt-record cancel attempts no writes")
      checks += 1
      let observed = await vault.storedBytes(recordKey(current.transactionID))
      try require(observed == corrupt, "the resumed corrupt record stays as observed")
      checks += 1
      await vault.installFixtureBytes(recordBefore, key: recordKey(current.transactionID))
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID, "fence released after corrupt-record cancel")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      let pointerBefore = await vault.storedBytes(manifestKey)
      let recordBefore = await vault.storedBytes(recordKey(current.transactionID))
      await vault.resetExportCounters()
      await vault.pauseRecordReadOnce()
      var cancelled = false
      do {
        _ = try await runControlledExport(
          label: "record-valid-cancel", vault: vault, staging: staging,
          expectedTransactionID: current.transactionID, cancelBeforeResume: true) { 0 }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "record-stage last-await cancel throws CancellationError")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "record-stage cancel attempts no writes")
      checks += 1
      let pointerAfter = await vault.storedBytes(manifestKey)
      let recordAfter = await vault.storedBytes(recordKey(current.transactionID))
      try require(pointerAfter == pointerBefore && recordAfter == recordBefore,
                  "record-stage cancel preserves pointer and record")
      checks += 1
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID,
                  "fence released after record-stage cancellation")
      checks += 1
    }
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      await vault.cancelJournalReads(true)
      await vault.resetExportCounters()
      var cancelled = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch is CancellationError { cancelled = true }
      try require(cancelled, "journal-read cancellation is never mapped to a recovery error")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "journal cancellation attempts no writes")
      checks += 1
      await vault.cancelJournalReads(false)
      let snapshot = try await staging.loadShadowSnapshot()
      try require(snapshot?.transactionID == current.transactionID,
                  "fence released after journal-read cancellation")
      checks += 1
    }
    return checks
  }

  /// The controlled-await helper must report every terminal result: a completed
  /// export (success or failure) is discriminated immediately instead of
  /// leaving the phase wait hanging.
  private static func checkTerminalReporting(codec: PiliAccountLiveMemoryShadowCodec,
                                             base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let (vault, staging, _, current) = try await makeAdoptedVault(codec: codec, base: base)
      let task = startExportTask(vault: vault, staging: staging,
                                 expectedTransactionID: current.transactionID)
      let paused = await vault.waitUntilPhaseOrTerminal()
      try require(!paused, "completed export is reported terminal, not an endless wait")
      checks += 1
      let outcome = await vault.terminalOutcome()
      try require(outcome == "success", "early success is reported as success")
      checks += 1
      let value = try await task.value
      try require(value.transactionID == current.transactionID, "early success keeps the result")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let task = startExportTask(vault: vault, staging: staging,
                                 expectedTransactionID: UUID())
      let paused = await vault.waitUntilPhaseOrTerminal()
      try require(!paused, "failed export is reported terminal, not an endless wait")
      checks += 1
      let outcome = await vault.terminalOutcome()
      try require(outcome == "failure", "early failure is reported as failure")
      checks += 1
      var surfaced = false
      do { _ = try await task.value }
      catch PiliAccountEnvelopeStagingError.shadowUnavailable { surfaced = true }
      try require(surfaced, "early failure keeps the exact typed outcome")
      checks += 1
    }
    return checks
  }

  /// A schema-3 adoption is a nil-pointer no-op that must never fabricate a new
  /// association or change the exported bytes.
  private static func checkAdoptionNoOp(codec: PiliAccountLiveMemoryShadowCodec,
                                        base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let (vault, staging, store, current) = try await makeAdoptedVault(codec: codec, base: base)
    let first = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
    let second = try await store.adoptMissingIdentities()
    try require(second.transactionID == nil && second.adopted == 0 && second.adoptedIdentities.isEmpty,
                "schema-3 adoption is a nil-pointer no-op")
    checks += 1
    let again = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
    try require(again.envelopeBytes == first.envelopeBytes && again.envelopeSHA256 == first.envelopeSHA256,
                "no-op adoption never fabricates a new pointer")
    checks += 1
    return checks
  }

  /// Real Keychain publication and export: produces the cross-runtime artifacts
  /// and proves a same-process NEW store instance over the same namespace
  /// re-exports byte-identical evidence. This is explicitly not a process-kill
  /// proof, and this row is read-only by construction but not attempt-counted.
  private static func checkActualKeychainArtifacts(
    codec: PiliAccountLiveMemoryShadowCodec, base: PiliAccountLiveMemoryShadow,
    metadataPath: String, wirePath: String, sourceSHA: String, workflowSHA: String
  ) async throws -> Int {
    var checks = 0
    let namespace = UUID()
    let vault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    try await vault.importShadow(codec.encode(base))
    _ = try await store.adoptMissingIdentities()
    guard let current = try await vault.loadShadowSnapshot() else {
      throw ExportFixtureError.failed("missing real-Keychain shadow")
    }
    try require(current.envelope.schemaVersion == 3, "real Keychain adoption publishes schema 3")
    checks += 1
    let export = try await vault.exportCurrentShadow(expectedTransactionID: current.transactionID)
    let wireURL = URL(fileURLWithPath: wirePath)
    try export.envelopeBytes.write(to: wireURL, options: .atomic)
    let reread = try Data(contentsOf: wireURL)
    try require(reread == export.envelopeBytes, "wire file is the exact exported bytes")
    checks += 1
    let digest = sha256Hex(reread)
    try require(digest == export.envelopeSHA256, "wire digest matches the export digest")
    checks += 1
    let decoded = try codec.decode(reread)
    try require(decoded.schemaVersion == 3, "exported artifact strictly decodes as schema 3")
    checks += 1
    let workflowValue: Any
    if workflowSHA.isEmpty {
      workflowValue = NSNull()
    } else {
      workflowValue = workflowSHA
    }
    let metadata: [String: Any] = [
      "schema": "pili.account.schema3-export.v1",
      "sourceSHA": sourceSHA,
      "workflowSHA": workflowValue,
      "transactionID": export.transactionID.uuidString.lowercased(),
      "envelopeSchemaVersion": 3,
      "envelopeByteCount": reread.count,
      "envelopeSHA256": digest,
      "wireFileName": wireURL.lastPathComponent,
    ]
    let metadataBytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    try metadataBytes.write(to: URL(fileURLWithPath: metadataPath), options: .atomic)
    let parsedMetadata = try JSONSerialization.jsonObject(with: metadataBytes)
    try require(parsedMetadata is [String: Any], "metadata is a JSON object")
    checks += 1
    let reopenedVault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
    let reopened = try await reopenedVault.exportCurrentShadow(expectedTransactionID: export.transactionID)
    try require(reopened.envelopeBytes == export.envelopeBytes,
                "same-process Keychain reopen keeps the exact bytes")
    checks += 1
    try require(reopened.envelopeSHA256 == digest, "same-process Keychain reopen keeps the digest")
    checks += 1
    return checks
  }

  static func main() async throws {
    guard CommandLine.arguments.count == 6 else {
      throw ExportFixtureError.failed(
        "expected liveMemory metadata wire sourceSHA workflowSHA arguments")
    }
    let sourceSHA = CommandLine.arguments[4]
    let workflowSHA = CommandLine.arguments[5]
    try require(sourceSHA.count == 40, "validated source SHA is required")
    let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]],
          let value = cases.first(where: {
            $0["id"] as? String == fixtureCaseID
          })?["envelope"] else {
      throw ExportFixtureError.failed("actual Dart envelope missing")
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let codec = PiliAccountLiveMemoryShadowCodec()
    let base = try codec.decode(data)
    try require(base.schemaVersion == 2, "the actual Dart golden is a schema-2 envelope")
    try require(base.records.count == 3, "expected anonymous + two login records")
    var checks = try await checkFaultVaultBasics(codec: codec, base: base)
    checks += try await checkFreshAndInvalidJournal(codec: codec, base: base)
    checks += try await checkExportNegatives(codec: codec, base: base)
    checks += try await checkStoreBUnknown(codec: codec, base: base)
    checks += try await checkSameVaultContention(codec: codec, base: base)
    checks += try await checkCancellationAtAwaits(codec: codec, base: base)
    checks += try await checkTerminalReporting(codec: codec, base: base)
    checks += try await checkAdoptionNoOp(codec: codec, base: base)
    checks += try await checkActualKeychainArtifacts(
      codec: codec, base: base, metadataPath: CommandLine.arguments[2],
      wirePath: CommandLine.arguments[3], sourceSHA: sourceSHA, workflowSHA: workflowSHA)
    print("\(checks) native account envelope export checks passed")
    print("atomic read-only schema3 export; actual Keychain same-process new-instance reopen "
          + "(not a process-kill proof); zero attempted writes/removes asserted on every "
          + "fault-vault export row; the real-Keychain artifact row is read-only but not "
          + "attempt-counted")
  }
}
