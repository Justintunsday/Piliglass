import CryptoKit
import Foundation

private enum ExportFixtureError: Error { case failed(String), injected }

/// Fault-injecting secret store for the atomic export contract. Every write and
/// remove ATTEMPT is counted whether or not it succeeds, so the export rows can
/// prove zero attempted durable mutations. Reads can be paused at the
/// manifest/record stage, failed, or cancelled deterministically; fixture setup
/// installs journal bytes directly without counting them as export attempts.
private actor ExportFaultVault: PiliAccountSecretStore {
  private let pointerKey = "account-envelope-shadow-manifest-v2"
  private let recoveryJournalKey = "account-envelope-recovery-journal-v1"
  private var values: [String: Data] = [:]
  private var writeAttempts = 0
  private var removeAttempts = 0
  private var pauseManifestRead = false
  private var manifestReadSuspended: CheckedContinuation<Void, Never>?
  private var manifestReadObserver: CheckedContinuation<Void, Never>?
  private var pauseRecordRead = false
  private var recordReadSuspended: CheckedContinuation<Void, Never>?
  private var recordReadObserver: CheckedContinuation<Void, Never>?
  private var journalReadFails = false
  private var journalReadCancels = false

  func writeAttemptCount() -> Int { writeAttempts }
  func removeAttemptCount() -> Int { removeAttempts }
  func storedBytes(_ key: String) -> Data? { values[key] }
  func installFixtureBytes(_ data: Data, key: String) { values[key] = data }
  func resetExportCounters() {
    writeAttempts = 0
    removeAttempts = 0
  }
  func failJournalReads(_ enabled: Bool) { journalReadFails = enabled }
  func cancelJournalReads(_ enabled: Bool) { journalReadCancels = enabled }
  func pauseManifestReadOnce() { pauseManifestRead = true }
  func waitUntilManifestReadPaused() async {
    if manifestReadSuspended != nil { return }
    await withCheckedContinuation { manifestReadObserver = $0 }
  }
  func resumeManifestRead() {
    manifestReadSuspended?.resume()
    manifestReadSuspended = nil
  }
  func pauseRecordReadOnce() { pauseRecordRead = true }
  func waitUntilRecordReadPaused() async {
    if recordReadSuspended != nil { return }
    await withCheckedContinuation { recordReadObserver = $0 }
  }
  func resumeRecordRead() {
    recordReadSuspended?.resume()
    recordReadSuspended = nil
  }

  func read(_ key: String) async throws -> Data? {
    if key == recoveryJournalKey {
      if journalReadCancels { throw CancellationError() }
      if journalReadFails { throw ExportFixtureError.injected }
      return values[key]
    }
    if key == pointerKey {
      if pauseManifestRead {
        pauseManifestRead = false
        await withCheckedContinuation {
          manifestReadSuspended = $0
          manifestReadObserver?.resume()
          manifestReadObserver = nil
        }
      }
      return values[key]
    }
    if key.hasPrefix("account-envelope-shadow-v2.") {
      if pauseRecordRead {
        pauseRecordRead = false
        await withCheckedContinuation {
          recordReadSuspended = $0
          recordReadObserver?.resume()
          recordReadObserver = nil
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

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func require(_ condition: Bool, _ label: String) throws {
    guard condition else { throw ExportFixtureError.failed(label) }
  }

  private static func recordKey(_ id: UUID) -> String {
    "account-envelope-shadow-v2.\(id.uuidString.lowercased())"
  }

  private static func makeJournal(_ fill: String, kind: String) throws -> Data {
    let journal = PiliAccountEnvelopeRecoveryJournal(
      attemptedTransactionID: UUID(), expectedPreviousTransactionID: nil,
      attemptedCandidateSHA256: String(repeating: fill, count: 64), kind: kind)
    return try PiliAccountEnvelopeRecoveryJournal.encode(journal)
  }

  /// Rows 1-6 of the proof matrix: byte-exact zero-attempt success, absent and
  /// schema-2 refusals, stale/historical-pointer refusals, and persistent
  /// journal evidence failing the export closed.
  private static func checkFaultVaultBasics(codec: PiliAccountLiveMemoryShadowCodec,
                                            base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      try await staging.importShadow(codec.encode(base))
      _ = try await store.adoptMissingIdentities()
      guard let current = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing adopted shadow")
      }
      try require(current.envelope.schemaVersion == 3, "adoption publishes schema 3")
      checks += 1
      guard let storedRecord = await vault.storedBytes(recordKey(current.transactionID)) else {
        throw ExportFixtureError.failed("missing stored record bytes")
      }
      let storedPointer = await vault.storedBytes(manifestKey)
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
      let pointerAfter = await vault.storedBytes(manifestKey)
      let recordAfter = await vault.storedBytes(recordKey(current.transactionID))
      try require(pointerAfter == storedPointer && recordAfter == storedRecord,
                  "pointer and record survive the export byte-identically")
      checks += 1
      let journalAfter = await vault.storedBytes(journalKey)
      try require(journalAfter == nil, "no recovery journal appears during the export")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.shadowUnavailable { surfaced = true }
      try require(surfaced, "absent pointer exports shadowUnavailable")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "absent-pointer refusal is zero-write")
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
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      try await staging.importShadow(codec.encode(base))
      _ = try await store.adoptMissingIdentities()
      guard let first = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing first publication")
      }
      try await staging.importShadow(codec.encode(base))
      guard let second = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing second publication")
      }
      try require(second.transactionID != first.transactionID, "raw follow-up moves the pointer")
      checks += 1
      let historical = try await staging.loadPublishedCandidate(transactionID: first.transactionID)
      try require(historical.schemaVersion == 3, "historical adopted candidate stays readable")
      checks += 1
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: first.transactionID) }
      catch PiliAccountEnvelopeStagingError.staleExport { surfaced = true }
      try require(surfaced, "historical candidate is never substituted for the current pointer")
      checks += 1
      let winner = try await staging.loadShadowSnapshot()
      try require(winner?.transactionID == second.transactionID, "winner stays the new pointer")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      try await staging.importShadow(codec.encode(base))
      _ = try await store.adoptMissingIdentities()
      guard let current = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing journal fixture shadow")
      }
      let journalBytes = try makeJournal("a", kind: "export-qa")
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "persistent journal fails the export closed")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(preserved == journalBytes, "journal bytes are preserved exactly")
      checks += 1
      try require(writeAttempts == 0 && removeAttempts == 0, "journal refusal attempts no writes")
      checks += 1
    }
    return checks
  }

  /// The export must read persistent journal evidence fresh: a transaction
  /// store's cached clean recovery state cannot hide a journal that appears
  /// afterwards, and corrupt/unreadable journals fail closed by exact type.
  private static func checkFreshAndInvalidJournal(codec: PiliAccountLiveMemoryShadowCodec,
                                                  base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      try await staging.importShadow(codec.encode(base))
      _ = try await store.adoptMissingIdentities()
      guard let current = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing fresh-read shadow")
      }
      let cached = try await store.loadPersistentRecovery()
      try require(cached == nil, "transaction store carries a cached clean recovery state")
      checks += 1
      let journalBytes = try makeJournal("b", kind: "export-qa")
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "export reads journal evidence fresh, not from the cached store")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "fresh journal bytes are preserved")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let corrupt = Data("not-a-canonical-journal".utf8)
      await vault.installFixtureBytes(corrupt, key: journalKey)
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.invalidRecoveryJournal { surfaced = true }
      try require(surfaced, "corrupt journal surfaces invalidRecoveryJournal")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(preserved == corrupt, "corrupt journal bytes are preserved")
      checks += 1
      try require(writeAttempts == 0 && removeAttempts == 0, "corrupt-journal refusal is zero-write")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let journalBytes = try makeJournal("c", kind: "export-qa")
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      await vault.failJournalReads(true)
      await vault.resetExportCounters()
      var surfaced = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "unreadable journal fails closed as unresolvedRecovery")
      checks += 1
      await vault.failJournalReads(false)
      let preserved = await vault.storedBytes(journalKey)
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(preserved == journalBytes, "unreadable journal bytes are preserved")
      checks += 1
      try require(writeAttempts == 0 && removeAttempts == 0, "unreadable-journal refusal is zero-write")
      checks += 1
    }
    return checks
  }

  /// A same-vault legitimate writer must meet the export's operation fence while
  /// the export is paused after its journal read; the winner and the export are
  /// preserved, and after release a new publication makes the old pointer stale.
  private static func checkSameVaultContention(codec: PiliAccountLiveMemoryShadowCodec,
                                               base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let vault = ExportFaultVault()
    let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
    let store = PiliAccountEnvelopeTransactionStore(vault: staging)
    try await staging.importShadow(codec.encode(base))
    _ = try await store.adoptMissingIdentities()
    guard let current = try await staging.loadShadowSnapshot() else {
      throw ExportFixtureError.failed("missing contended shadow")
    }
    let pointerBefore = await vault.storedBytes(manifestKey)
    await vault.resetExportCounters()
    await vault.pauseManifestReadOnce()
    let exportTask = Task {
      try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
    }
    await vault.waitUntilManifestReadPaused()
    var rejected = false
    do { _ = try await staging.importShadow(codec.encode(base)) }
    catch PiliAccountEnvelopeStagingError.operationInProgress { rejected = true }
    try require(rejected, "same-vault writer meets the export operation fence")
    checks += 1
    let pointerDuring = await vault.storedBytes(manifestKey)
    try require(pointerDuring == pointerBefore, "rejected writer leaves the winner untouched")
    checks += 1
    await vault.resumeManifestRead()
    let export = try await exportTask.value
    try require(export.transactionID == current.transactionID, "paused export resumes on the pinned pointer")
    checks += 1
    let writeAttempts = await vault.writeAttemptCount()
    let removeAttempts = await vault.removeAttemptCount()
    try require(writeAttempts == 0 && removeAttempts == 0, "contended export still attempts zero mutations")
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

  /// Cancellation at the manifest/record awaits (explicit resume of the paused
  /// read) and a cancellation thrown by the journal read itself must surface the
  /// exact CancellationError, attempt no writes, preserve state, and release the
  /// fence for a later valid operation.
  private static func checkCancellationBoundaries(codec: PiliAccountLiveMemoryShadowCodec,
                                                  base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      try await staging.importShadow(codec.encode(base))
      _ = try await store.adoptMissingIdentities()
      guard let current = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing manifest-cancel shadow")
      }
      let pointerBefore = await vault.storedBytes(manifestKey)
      let recordBefore = await vault.storedBytes(recordKey(current.transactionID))
      await vault.resetExportCounters()
      await vault.pauseManifestReadOnce()
      let task = Task {
        try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      }
      await vault.waitUntilManifestReadPaused()
      task.cancel()
      await vault.resumeManifestRead()
      var cancelled = false
      do { _ = try await task.value } catch is CancellationError { cancelled = true }
      try require(cancelled, "manifest-stage cancel throws CancellationError")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "cancelled export attempts no writes")
      checks += 1
      let pointerAfter = await vault.storedBytes(manifestKey)
      let recordAfter = await vault.storedBytes(recordKey(current.transactionID))
      try require(pointerAfter == pointerBefore && recordAfter == recordBefore,
                  "cancellation preserves pointer and record")
      checks += 1
      let cleanup = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      try require(cleanup.transactionID == current.transactionID, "fence released after cancellation")
      checks += 1
    }
    do {
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      try await staging.importShadow(codec.encode(base))
      _ = try await store.adoptMissingIdentities()
      guard let current = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing record-cancel shadow")
      }
      let pointerBefore = await vault.storedBytes(manifestKey)
      let recordBefore = await vault.storedBytes(recordKey(current.transactionID))
      await vault.resetExportCounters()
      await vault.pauseRecordReadOnce()
      let task = Task {
        try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
      }
      await vault.waitUntilRecordReadPaused()
      task.cancel()
      await vault.resumeRecordRead()
      var cancelled = false
      do { _ = try await task.value } catch is CancellationError { cancelled = true }
      try require(cancelled, "record-stage cancel throws CancellationError")
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
      let vault = ExportFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      try await staging.importShadow(codec.encode(base))
      _ = try await store.adoptMissingIdentities()
      guard let current = try await staging.loadShadowSnapshot() else {
        throw ExportFixtureError.failed("missing journal-cancel shadow")
      }
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

  /// A schema-3 adoption is a nil-pointer no-op that must never fabricate a new
  /// association or change the exported bytes.
  private static func checkAdoptionNoOp(codec: PiliAccountLiveMemoryShadowCodec,
                                        base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let vault = ExportFaultVault()
    let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
    let store = PiliAccountEnvelopeTransactionStore(vault: staging)
    try await staging.importShadow(codec.encode(base))
    _ = try await store.adoptMissingIdentities()
    guard let current = try await staging.loadShadowSnapshot() else {
      throw ExportFixtureError.failed("missing no-op shadow")
    }
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
  /// proof.
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
    checks += try await checkSameVaultContention(codec: codec, base: base)
    checks += try await checkCancellationBoundaries(codec: codec, base: base)
    checks += try await checkAdoptionNoOp(codec: codec, base: base)
    checks += try await checkActualKeychainArtifacts(
      codec: codec, base: base, metadataPath: CommandLine.arguments[2],
      wirePath: CommandLine.arguments[3], sourceSHA: sourceSHA, workflowSHA: workflowSHA)
    print("\(checks) native account envelope export checks passed")
    print("atomic read-only schema3 export; actual Keychain same-process new-instance reopen "
          + "(not a process-kill proof); zero attempted writes/removes on every export row")
  }
}
