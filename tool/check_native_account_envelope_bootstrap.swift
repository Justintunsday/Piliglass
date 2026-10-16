import CryptoKit
import Foundation

private enum BootstrapFixtureError: Error { case failed(String), injected }

private func bootstrapSHA256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Fault-injecting secret store for the create-only bootstrap contract. Every
/// read, write and remove ATTEMPT is counted so each row can assert the exact
/// attempted mutation counts. Faults are keyed by intent (journal/manifest/
/// record/descriptor/pointer) and, where a stage needs targeting, by the
/// absolute journal-read ordinal, so the journal write / verify / clear stages
/// are exercised deterministically without sleeps. Terminal reporting is
/// first-write-wins: a task outcome is never rewritten by cleanup.
private actor BootstrapFaultVault: PiliAccountSecretStore {
  private let pointerKey = "account-envelope-shadow-manifest-v2"
  private let recoveryJournalKey = "account-envelope-recovery-journal-v1"
  private var values: [String: Data] = [:]
  private var readAttempts = 0
  private var writeAttempts = 0
  private var removeAttempts = 0
  private var journalReadCount = 0
  private var failJournalReads = false
  private var failJournalReadsTyped = false
  private var cancelJournalReads = false
  private var journalReadFailAt = 0
  private var journalReadPauseAt = 0
  private var journalReadSuspended: CheckedContinuation<Void, Never>?
  private var journalWriteFailures = 0
  private var journalWriteCommitThenThrow = false
  private var journalWriteStoresTampered = false
  private var failJournalRemoves = false
  private var pauseManifestRead = false
  private var manifestReadSuspended: CheckedContinuation<Void, Never>?
  private var recordWriteFailures = 0
  private var recordReadCount = 0
  private var recordReadFailAt = 0
  private var recordReadMismatchAt = 0
  private var descriptorWriteFailures = 0
  private var descriptorReadCount = 0
  private var descriptorReadMismatchAt = 0
  private var pointerWriteFailures = 0
  private var pointerWriteCommitThenThrow = false
  private var pointerReadFailures = 0
  private var pointerReadFailSkip = 0
  private var scriptTerminal: String?
  private var phaseWaiters: [CheckedContinuation<Void, Never>] = []

  func readAttemptCount() -> Int { readAttempts }
  func writeAttemptCount() -> Int { writeAttempts }
  func removeAttemptCount() -> Int { removeAttempts }
  func storedBytes(_ key: String) -> Data? { values[key] }
  func storedSnapshot() -> [String: Data] { values }
  func installFixtureBytes(_ data: Data, key: String) { values[key] = data }
  func rawRemove(_ key: String) { values.removeValue(forKey: key) }
  func resetCounters() {
    readAttempts = 0
    writeAttempts = 0
    removeAttempts = 0
    journalReadCount = 0
    recordReadCount = 0
    descriptorReadCount = 0
  }

  func failJournalReads(_ enabled: Bool) { failJournalReads = enabled }
  func failJournalReadsTyped(_ enabled: Bool) { failJournalReadsTyped = enabled }
  func cancelJournalReads(_ enabled: Bool) { cancelJournalReads = enabled }
  func failJournalReadAt(_ ordinal: Int) { journalReadFailAt = ordinal }
  func pauseJournalReadAt(_ ordinal: Int) { journalReadPauseAt = ordinal }
  func resumeJournalRead() {
    journalReadSuspended?.resume()
    journalReadSuspended = nil
  }
  func failJournalWrites(_ count: Int) { journalWriteFailures = count }
  func journalCommitThenThrow(_ enabled: Bool) { journalWriteCommitThenThrow = enabled }
  func journalStoresTampered(_ enabled: Bool) { journalWriteStoresTampered = enabled }
  func failJournalRemoves(_ enabled: Bool) { failJournalRemoves = enabled }
  func pauseManifestReadOnce() { pauseManifestRead = true }
  func resumeManifestRead() {
    manifestReadSuspended?.resume()
    manifestReadSuspended = nil
  }
  func failRecordWrites(_ count: Int) { recordWriteFailures = count }
  func failRecordReadAt(_ ordinal: Int) { recordReadFailAt = ordinal }
  func recordReadBackMismatchAt(_ ordinal: Int) { recordReadMismatchAt = ordinal }
  func failDescriptorWrites(_ count: Int) { descriptorWriteFailures = count }
  func descriptorReadBackMismatchAt(_ ordinal: Int) { descriptorReadMismatchAt = ordinal }
  func failPointerWrites(_ count: Int) { pointerWriteFailures = count }
  func pointerCommitThenThrow(_ enabled: Bool) { pointerWriteCommitThenThrow = enabled }
  /// Fails the pointer read that follows `skip` further successful pointer
  /// reads. The create-only flow reads the pointer once for its snapshot and
  /// once more for the acknowledgment, so skip 1 targets exactly the
  /// unreadable-ancor boundary.
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
  func noteTerminal(_ outcome: String) {
    if scriptTerminal == nil { scriptTerminal = outcome }
    let waiters = phaseWaiters
    phaseWaiters = []
    for waiter in waiters { waiter.resume() }
  }
  func terminalOutcome() -> String? { scriptTerminal }
  func waitUntilPhaseOrTerminal() async -> Bool {
    if journalReadSuspended != nil || manifestReadSuspended != nil { return true }
    if scriptTerminal != nil { return false }
    await withCheckedContinuation { phaseWaiters.append($0) }
    return journalReadSuspended != nil || manifestReadSuspended != nil
  }

  func read(_ key: String) async throws -> Data? {
    readAttempts += 1
    if key == recoveryJournalKey {
      journalReadCount += 1
      if cancelJournalReads { throw CancellationError() }
      if failJournalReads { throw BootstrapFixtureError.injected }
      if failJournalReadsTyped { throw PiliAccountEnvelopeStagingError.missingRecord }
      if journalReadFailAt != 0, journalReadCount == journalReadFailAt {
        journalReadFailAt = 0
        throw BootstrapFixtureError.injected
      }
      if journalReadPauseAt != 0, journalReadCount == journalReadPauseAt {
        journalReadPauseAt = 0
        await withCheckedContinuation { continuation in
          journalReadSuspended = continuation
          let waiters = phaseWaiters
          phaseWaiters = []
          for waiter in waiters { waiter.resume() }
        }
      }
      return values[key]
    }
    if key == pointerKey {
      if pointerReadFailures > 0 {
        if pointerReadFailSkip > 0 {
          pointerReadFailSkip -= 1
        } else {
          if pointerReadFailures != Int.max { pointerReadFailures -= 1 }
          throw BootstrapFixtureError.injected
        }
      }
      if pauseManifestRead {
        pauseManifestRead = false
        await withCheckedContinuation { continuation in
          manifestReadSuspended = continuation
          let waiters = phaseWaiters
          phaseWaiters = []
          for waiter in waiters { waiter.resume() }
        }
      }
      return values[key]
    }
    if key.hasPrefix("account-envelope-shadow-descriptor-v2.") {
      descriptorReadCount += 1
      if descriptorReadMismatchAt != 0, descriptorReadCount == descriptorReadMismatchAt {
        descriptorReadMismatchAt = 0
        if let current = values[key] { return current + Data([0x00]) }
      }
      return values[key]
    }
    if key.hasPrefix("account-envelope-shadow-v2.") {
      recordReadCount += 1
      if recordReadFailAt != 0, recordReadCount == recordReadFailAt {
        recordReadFailAt = 0
        throw BootstrapFixtureError.injected
      }
      if recordReadMismatchAt != 0, recordReadCount == recordReadMismatchAt {
        recordReadMismatchAt = 0
        if let current = values[key] { return current + Data([0x00]) }
      }
      return values[key]
    }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    writeAttempts += 1
    if key == recoveryJournalKey {
      if journalWriteFailures > 0 {
        journalWriteFailures -= 1
        throw BootstrapFixtureError.injected
      }
      if journalWriteStoresTampered {
        journalWriteStoresTampered = false
        values[key] = data + Data([0x00])
        return
      }
      values[key] = data
      if journalWriteCommitThenThrow {
        journalWriteCommitThenThrow = false
        throw BootstrapFixtureError.injected
      }
      return
    }
    if key == pointerKey {
      if pointerWriteFailures > 0 {
        pointerWriteFailures -= 1
        throw BootstrapFixtureError.injected
      }
      values[key] = data
      if pointerWriteCommitThenThrow {
        pointerWriteCommitThenThrow = false
        throw BootstrapFixtureError.injected
      }
      return
    }
    if key.hasPrefix("account-envelope-shadow-descriptor-v2.") {
      if descriptorWriteFailures > 0 {
        descriptorWriteFailures -= 1
        throw BootstrapFixtureError.injected
      }
      values[key] = data
      return
    }
    if key.hasPrefix("account-envelope-shadow-v2.") {
      if recordWriteFailures > 0 {
        recordWriteFailures -= 1
        throw BootstrapFixtureError.injected
      }
      values[key] = data
      return
    }
    values[key] = data
  }

  func remove(_ key: String) async throws {
    removeAttempts += 1
    if key == recoveryJournalKey, failJournalRemoves {
      throw BootstrapFixtureError.injected
    }
    values.removeValue(forKey: key)
  }
}

/// Driver-local typed negative oracle for the capture->export association. It
/// is explicitly NOT a production API, binding or identity: it validates the
/// exported schema-3 envelope against the independent schema-2 capture, using
/// explicit expected values rather than re-reading a single input. Labels are
/// durable capture-local evidence, never request authority.
private struct ExportAssociationFixtureOracle {
  let codec: PiliAccountLiveMemoryShadowCodec

  private static let zeroPointer = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

  func validate(capture: PiliAccountLiveMemoryShadow, exported: PiliAccountLiveMemoryShadow,
                pointer: UUID, envelopeSHA256: String, captureRevision: Int64?) throws {
    // The published pointer must be an actual operation identity, not the
    // zero placeholder; the driver additionally pins it to the vault snapshot
    // and the export receipt with explicit expected/actual comparisons.
    guard pointer != Self.zeroPointer else {
      throw BootstrapFixtureError.failed("association: placeholder pointer")
    }
    guard capture.schemaVersion == 2, exported.schemaVersion == 3 else {
      throw BootstrapFixtureError.failed("association: envelope schemas")
    }
    guard exported.revision == capture.revision,
          exported.scope == capture.scope,
          exported.identityScope == capture.identityScope,
          exported.durableIdentityConfigured == false,
          exported.durabilityVerified == false,
          exported.authoritySwitchAllowed == false,
          exported.nativeWritesAllowed == false else {
      throw BootstrapFixtureError.failed("association: carried envelope fields")
    }
    if let captureRevision, captureRevision != capture.revision {
      throw BootstrapFixtureError.failed("association: capture revision")
    }
    guard exported.records.count == capture.records.count else {
      throw BootstrapFixtureError.failed("association: record count")
    }
    var identities = Set<PiliCookieUTF16>()
    for (captureRecord, exportedRecord) in zip(capture.records, exported.records) {
      guard captureRecord.durableIdentity == nil else {
        throw BootstrapFixtureError.failed("association: schema-2 capture carries an identity")
      }
      guard exportedRecord.record == captureRecord.record,
            exportedRecord.generation == captureRecord.generation,
            exportedRecord.storageKeyUnits == captureRecord.storageKeyUnits,
            exportedRecord.mid == captureRecord.mid,
            exportedRecord.isLogin == captureRecord.isLogin,
            exportedRecord.accessKeyUnits == captureRecord.accessKeyUnits,
            exportedRecord.refreshTokenUnits == captureRecord.refreshTokenUnits,
            exportedRecord.persistedPurposes == captureRecord.persistedPurposes,
            exportedRecord.activated == captureRecord.activated,
            exportedRecord.jar == captureRecord.jar else {
        throw BootstrapFixtureError.failed("association: record projection")
      }
      if captureRecord.record == 0 {
        guard exportedRecord.durableIdentity == nil else {
          throw BootstrapFixtureError.failed("association: anonymous record identity")
        }
      } else {
        guard let identity = exportedRecord.durableIdentity,
              PiliAccountLiveMemoryShadow.isCanonicalDurableIdentity(identity),
              !identities.contains(identity) else {
          throw BootstrapFixtureError.failed("association: durable label")
        }
        identities.insert(identity)
      }
    }
    guard exported.storedOrder == capture.storedOrder,
          exported.ownerOrder == capture.ownerOrder,
          exported.selectionPurposes == capture.selectionPurposes,
          exported.selections == capture.selections,
          exported.history == capture.history else {
      throw BootstrapFixtureError.failed("association: orders/selections/history")
    }
    let highWater = capture.records.dropFirst().map(\.generation).max() ?? 0
    guard exported.effectiveGenerationHighWater == highWater else {
      throw BootstrapFixtureError.failed("association: generation high-water")
    }
    // Digest binding: the canonical encoding of the exported envelope must
    // equal the digest computed over the exact produced wire bytes.
    guard bootstrapSHA256Hex(try codec.encode(exported)) == envelopeSHA256 else {
      throw BootstrapFixtureError.failed("association: byte digest binding")
    }
  }
}

@main private struct AccountEnvelopeBootstrapChecks {
  private static let manifestKey = "account-envelope-shadow-manifest-v2"
  private static let journalKey = "account-envelope-recovery-journal-v1"
  private static let fixtureCaseID = "stored-10-2-owner-2-10"
  private static let followerKind = "test-follower"

  private static func sha256Hex(_ data: Data) -> String {
    bootstrapSHA256Hex(data)
  }

  private static func require(_ condition: Bool, _ label: String) throws {
    guard condition else { throw BootstrapFixtureError.failed(label) }
  }

  private static func isInjected(_ error: any Error) -> Bool {
    if let fixture = error as? BootstrapFixtureError, case .injected = fixture { return true }
    return false
  }

  private static func recordKey(_ id: UUID) -> String {
    "account-envelope-shadow-v2.\(id.uuidString.lowercased())"
  }

  private static func descriptorKey(_ id: UUID) -> String {
    "account-envelope-shadow-descriptor-v2.\(id.uuidString.lowercased())"
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

  private static func expectedJournalBytes(attemptedID: UUID, candidate: Data) throws -> Data {
    let journal = PiliAccountEnvelopeRecoveryJournal(
      attemptedTransactionID: attemptedID, expectedPreviousTransactionID: nil,
      attemptedCandidateSHA256: sha256Hex(candidate),
      kind: PiliAccountEnvelopeRecoveryJournal.bootstrapKind)
    return try PiliAccountEnvelopeRecoveryJournal.encode(journal)
  }

  /// A schema-2-shaped envelope whose records array exceeds the codec's strict
  /// 256-record ceiling: only the production codec's resource limit can reject
  /// it, with all projected fields otherwise intact.
  private static func resourceLimitedSchemaTwoEnvelope(
    codec: PiliAccountLiveMemoryShadowCodec, base: PiliAccountLiveMemoryShadow
  ) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: codec.encode(base)) as? [String: Any],
          var records = object["records"] as? [[String: Any]],
          let sample = records.dropFirst().first else {
      throw BootstrapFixtureError.failed("schema-2 records expected")
    }
    while records.count < 257 {
      records.append(sample)
    }
    object["records"] = records
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func makeAdoptedVault(
    codec: PiliAccountLiveMemoryShadowCodec, base: PiliAccountLiveMemoryShadow
  ) async throws -> (BootstrapFaultVault, PiliAccountEnvelopeStagingStore,
                     PiliAccountEnvelopeTransactionStore, PiliAccountEnvelopeSnapshot) {
    let vault = BootstrapFaultVault()
    let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
    let store = PiliAccountEnvelopeTransactionStore(vault: staging)
    try await staging.importShadow(codec.encode(base))
    _ = try await store.adoptMissingIdentities()
    guard let current = try await staging.loadShadowSnapshot() else {
      throw BootstrapFixtureError.failed("missing adopted shadow")
    }
    return (vault, staging, store, current)
  }

  private static func startBootstrapTask(
    vault: BootstrapFaultVault, staging: PiliAccountEnvelopeStagingStore,
    input: Data, candidateTransactionID: UUID
  ) -> Task<PiliAccountEnvelopeStagingReceipt, any Error> {
    Task {
      do {
        let value = try await staging.bootstrapShadow(input,
                                                      candidateTransactionID: candidateTransactionID)
        await vault.noteTerminal("success")
        return value
      } catch {
        await vault.noteTerminal("failure")
        throw error
      }
    }
  }

  /// Controlled-await driver: waits for the injected phase or an early terminal
  /// result, runs the between-step, cancels when requested, and ALWAYS resumes
  /// and awaits the task on every path so nothing stays suspended behind a
  /// failed assertion.
  private static func runControlledBootstrap(
    label: String, vault: BootstrapFaultVault, staging: PiliAccountEnvelopeStagingStore,
    input: Data, candidateTransactionID: UUID, cancelBeforeResume: Bool,
    between: () async throws -> Int
  ) async throws -> (value: PiliAccountEnvelopeStagingReceipt, checks: Int) {
    let task = startBootstrapTask(vault: vault, staging: staging, input: input,
                                  candidateTransactionID: candidateTransactionID)
    do {
      let paused = await vault.waitUntilPhaseOrTerminal()
      try require(paused, "\(label): bootstrap reached a terminal result before the controlled await")
      let betweenChecks = try await between()
      if cancelBeforeResume {
        task.cancel()
      }
      await vault.resumeJournalRead()
      await vault.resumeManifestRead()
      let value = try await task.value
      return (value, betweenChecks)
    } catch {
      task.cancel()
      await vault.resumeJournalRead()
      await vault.resumeManifestRead()
      _ = try? await task.value
      await vault.noteTerminal("failure")
      throw error
    }
  }

  /// The enum literal owned by the transaction layer and the fixed constant
  /// owned by the staging layer must be the same kind string.
  private static func checkKindLiteralMatch() throws -> Int {
    try require(PiliAccountShadowUnresolvedWriteKind.bootstrap.rawValue
                == PiliAccountEnvelopeRecoveryJournal.bootstrapKind,
                "transaction bootstrap literal equals the staging lower-layer constant")
    try require(PiliAccountEnvelopeRecoveryJournal.bootstrapKind == "bootstrap",
                "the fixed bootstrap kind is the literal bootstrap")
    return 2
  }

  /// Rows 1-3 and 5-6 of the proof matrix: byte-exact zero-attempt success,
  /// present-pointer/schema/record/descriptor refusals, and codec errors that
  /// keep their exact existing types.
  private static func checkBootstrapBasics(codec: PiliAccountLiveMemoryShadowCodec,
                                           base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let data = try codec.encode(base)
      let pointerID = UUID()
      await vault.resetCounters()
      let receipt = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(receipt.transactionID == pointerID, "bootstrap receipt keeps the input operation ID")
      checks += 1
      try require(receipt.recoveredWriteAcknowledgment == false,
                  "clean bootstrap has no recovered acknowledgment")
      checks += 1
      let expectedManifest = try manifestBytes(transactionID: pointerID, byteCount: data.count,
                                               sha256: sha256Hex(data))
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter[manifestKey] == expectedManifest,
                  "bootstrap pointer bytes equal the independently built manifest")
      checks += 1
      try require(snapshotAfter[descriptorKey(pointerID)] == expectedManifest,
                  "bootstrap descriptor bytes equal the same independently built manifest")
      checks += 1
      try require(snapshotAfter[recordKey(pointerID)] == data,
                  "bootstrap record bytes equal the independent canonical encoding")
      checks += 1
      try require(snapshotAfter[journalKey] == nil, "clean bootstrap leaves no recovery journal")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 4 && removeAttempts == 0,
                  "clean bootstrap attempts exactly journal/record/descriptor/pointer writes")
      checks += 1
      let winner = try await staging.loadShadowSnapshot()
      try require(winner?.transactionID == pointerID && winner?.envelope == base,
                  "winner is the exact create-only publication")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      try await staging.importShadow(codec.encode(base))
      guard try await staging.loadShadowSnapshot() != nil else {
        throw BootstrapFixtureError.failed("missing raw publication")
      }
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      var refused = false
      do { _ = try await staging.bootstrapShadow(codec.encode(base), candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.bootstrapRefused { refused = true }
      try require(refused, "bootstrap refuses a present current pointer")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0,
                  "present-pointer refusal attempts no writes/removes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "present-pointer refusal preserves every vault byte")
      checks += 1
    }
    do {
      let (vault, staging, _, adopted) = try await makeAdoptedVault(codec: codec, base: base)
      try require(adopted.envelope.schemaVersion == 3, "adopted pointer is schema 3")
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      var refused = false
      do { _ = try await staging.bootstrapShadow(codec.encode(adopted.envelope),
                                                 candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.invalidBootstrap { refused = true }
      try require(refused, "schema-3 input is refused as invalidBootstrap")
      checks += 1
      let reads = await vault.readAttemptCount()
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(reads == 0 && writeAttempts == 0 && removeAttempts == 0,
                  "schema-3 refusal performs zero vault IO")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "schema-3 refusal preserves every vault byte")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      var codecError = false
      do { _ = try await staging.bootstrapShadow(Data("not-a-shadow".utf8),
                                                 candidateTransactionID: UUID()) }
      catch is PiliAccountLiveMemoryShadowError { codecError = true }
      try require(codecError, "undecodable input keeps its exact codec error type")
      checks += 1
      let reads = await vault.readAttemptCount()
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(reads == 0 && writeAttempts == 0 && removeAttempts == 0,
                  "codec rejection performs zero vault IO")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "codec rejection preserves every vault byte")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let limited = try resourceLimitedSchemaTwoEnvelope(codec: codec, base: base)
      await vault.resetCounters()
      var resourceError = false
      do { _ = try await staging.bootstrapShadow(limited, candidateTransactionID: UUID()) }
      catch PiliAccountLiveMemoryShadowError.resourceLimit { resourceError = true }
      try require(resourceError, "schema-2 resource-limit input keeps resourceLimit")
      checks += 1
      let reads = await vault.readAttemptCount()
      let writeAttempts = await vault.writeAttemptCount()
      try require(reads == 0 && writeAttempts == 0,
                  "resource-limit rejection performs zero vault IO")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let data = try codec.encode(base)
      let reusedID = UUID()
      await vault.installFixtureBytes(data, key: recordKey(reusedID))
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      var refused = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: reusedID) }
      catch PiliAccountEnvelopeStagingError.bootstrapRefused { refused = true }
      try require(refused, "record collision under the reused ID is refused")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore,
                  "record collision preserves the orphan record and every vault byte")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "record collision attempts no writes")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let data = try codec.encode(base)
      let reusedID = UUID()
      let orphanDescriptor = try manifestBytes(transactionID: reusedID, byteCount: data.count,
                                               sha256: sha256Hex(data))
      await vault.installFixtureBytes(orphanDescriptor, key: descriptorKey(reusedID))
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      var refused = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: reusedID) }
      catch PiliAccountEnvelopeStagingError.bootstrapRefused { refused = true }
      try require(refused, "orphan descriptor collision under the reused ID is refused")
      checks += 1
      let preserved = await vault.storedBytes(descriptorKey(reusedID))
      try require(preserved == orphanDescriptor, "the orphan descriptor is preserved exactly")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "descriptor collision attempts no writes")
      checks += 1
    }
    return checks
  }

  /// Row 4 and 8 of the proof matrix: the fresh journal fence (valid, corrupt,
  /// unreadable, forged kind) and the exact journal write/verify/clear failure
  /// outcomes, including the honest distinction between a fault that preserves
  /// journal bytes and one where the removal committed but its verification
  /// read failed (bytes then actually absent).
  private static func checkJournalFences(codec: PiliAccountLiveMemoryShadowCodec,
                                         base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let data = try codec.encode(base)
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let journalBytes = try expectedJournalBytes(attemptedID: UUID(), candidate: data)
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      await vault.resetCounters()
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "a valid journal fails bootstrap closed as unresolvedRecovery")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "journal bytes are preserved exactly")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0, "journal refusal attempts no writes")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let corrupt = Data("not-a-canonical-journal".utf8)
      await vault.installFixtureBytes(corrupt, key: journalKey)
      await vault.resetCounters()
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.invalidRecoveryJournal { surfaced = true }
      try require(surfaced, "corrupt journal surfaces invalidRecoveryJournal")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == corrupt, "corrupt journal bytes are preserved")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      try require(writeAttempts == 0, "corrupt-journal refusal attempts no writes")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let journalBytes = try expectedJournalBytes(attemptedID: UUID(), candidate: data)
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      await vault.failJournalReads(true)
      await vault.resetCounters()
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      await vault.failJournalReads(false)
      try require(surfaced, "unreadable journal fails closed as unresolvedRecovery")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "unreadable journal bytes are preserved")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      try require(writeAttempts == 0, "unreadable-journal refusal attempts no writes")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let journalBytes = try expectedJournalBytes(attemptedID: UUID(), candidate: data)
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      await vault.failJournalReadsTyped(true)
      await vault.resetCounters()
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      await vault.failJournalReadsTyped(false)
      try require(surfaced, "an unrelated typed journal read error fails closed as unresolvedRecovery")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "typed-error journal bytes are preserved")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      try require(writeAttempts == 0, "typed journal error attempts no writes")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let forged = PiliAccountEnvelopeRecoveryJournal(
        attemptedTransactionID: UUID(), expectedPreviousTransactionID: nil,
        attemptedCandidateSHA256: String(repeating: "a", count: 64), kind: "forged-kind")
      let forgedBytes = try PiliAccountEnvelopeRecoveryJournal.encode(forged)
      await vault.installFixtureBytes(forgedBytes, key: journalKey)
      await vault.resetCounters()
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "a forged-kind journal is treated as present, never skipped")
      checks += 1
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      var invalid = false
      do { _ = try await store.loadPersistentRecovery() }
      catch PiliAccountShadowTransactionError.invalidRecovery { invalid = true }
      try require(invalid, "cold load maps the unknown kind to invalidRecovery")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == forgedBytes, "the forged journal is preserved byte-exactly")
      checks += 1
      let fence = await store.pendingUnresolvedPublication
      try require(fence == nil, "an unknown kind never arms a fabricated pending fence")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.failJournalWrites(1)
      var surface = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch { surface = isInjected(error) }
      try require(surface, "a definite journal write failure surfaces the original write error")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore,
                  "definite journal write failure leaves no journal/record/descriptor/pointer")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 1 && removeAttempts == 0,
                  "definite journal write failure attempts exactly one write")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.journalCommitThenThrow(true)
      var surface = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch { surface = isInjected(error) }
      try require(surface,
                  "a committed-then-failed journal write with a verified clear surfaces the original error")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial,
                  "verified journal clear restores the pre-attempt vault state")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 1 && removeAttempts == 1,
                  "committed-then-failed journal write removes exactly the journal")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let expectedJournal = try expectedJournalBytes(attemptedID: pointerID, candidate: data)
      await vault.resetCounters()
      await vault.journalCommitThenThrow(true)
      await vault.failJournalRemoves(true)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced,
                  "an unverifiable journal clear after a failed write fails closed as unresolvedRecovery")
      checks += 1
      let retained = await vault.storedBytes(journalKey)
      try require(retained == expectedJournal,
                  "the fault that keeps the journal preserves its exact bytes")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 1 && removeAttempts == 1,
                  "the retained case attempts exactly the journal write and its refused remove")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let expectedJournal = try expectedJournalBytes(attemptedID: pointerID, candidate: data)
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.failJournalReadAt(2)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced, "a failed journal verification read fails closed as unresolvedRecovery")
      checks += 1
      let retained = await vault.storedBytes(journalKey)
      try require(retained == expectedJournal, "the unverified journal keeps its exact written bytes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter[recordKey(pointerID)] == nil
                  && snapshotAfter[descriptorKey(pointerID)] == nil
                  && snapshotAfter[manifestKey] == nil
                  && snapshotAfter != snapshotBefore,
                  "journal verification failure leaves exactly the journal evidence")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.journalStoresTampered(true)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.verificationFailed { surfaced = true }
      try require(surfaced, "a journal verification mismatch surfaces verificationFailed")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial, "the mismatched journal is removed and verified absent")
      checks += 1
    }
    return checks
  }

  /// Row 9 of the proof matrix: record/descriptor write IO throws propagate the
  /// original error, byte/decode mismatches surface verificationFailed, and an
  /// unverifiable journal clear fails closed as unresolvedRecovery with the
  /// journal's state determined by the actual fault (retained or absent).
  private static func checkCandidateFailures(codec: PiliAccountLiveMemoryShadowCodec,
                                             base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let data = try codec.encode(base)
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.failRecordWrites(1)
      var surface = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch { surface = isInjected(error) }
      try require(surface, "a record write IO error propagates the original error after cleanup")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial,
                  "record write failure cleanup removes record/descriptor/journal and no pointer appeared")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 2 && removeAttempts == 3,
                  "record write failure attempts journal+record writes and three cleanup removals")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.recordReadBackMismatchAt(2)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.verificationFailed { surfaced = true }
      try require(surfaced, "a record read-back mismatch surfaces verificationFailed")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial, "record mismatch cleanup restores the pre-attempt state")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 2 && removeAttempts == 3,
                  "record mismatch attempts no extra writes beyond the cleanup")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.failRecordReadAt(2)
      var surface = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch { surface = isInjected(error) }
      try require(surface, "a record read-back IO error propagates the original error after cleanup")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial, "record read error cleanup restores the pre-attempt state")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.failDescriptorWrites(1)
      var surface = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch { surface = isInjected(error) }
      try require(surface, "a descriptor write IO error propagates the original error after cleanup")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial, "descriptor write failure restores the pre-attempt state")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 3 && removeAttempts == 3,
                  "descriptor write failure attempts journal+record+descriptor writes and three removals")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.descriptorReadBackMismatchAt(2)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.verificationFailed { surfaced = true }
      try require(surfaced, "a descriptor read-back mismatch surfaces verificationFailed")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial, "descriptor mismatch cleanup restores the pre-attempt state")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let expectedJournal = try expectedJournalBytes(attemptedID: pointerID, candidate: data)
      await vault.resetCounters()
      await vault.failRecordWrites(1)
      await vault.failJournalRemoves(true)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced,
                  "an unverifiable cleanup clear fails closed as unresolvedRecovery")
      checks += 1
      let retained = await vault.storedBytes(journalKey)
      try require(retained == expectedJournal,
                  "the refused remove keeps the exact journal bytes for later classification")
      checks += 1
      let record = await vault.storedBytes(recordKey(pointerID))
      let descriptor = await vault.storedBytes(descriptorKey(pointerID))
      try require(record == nil && descriptor == nil,
                  "the candidate record/descriptor do not survive the failed cleanup")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      await vault.resetCounters()
      await vault.failRecordWrites(1)
      await vault.failJournalReadAt(3)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { surfaced = true }
      try require(surfaced,
                  "a committed remove with a failed verification read still fails closed")
      checks += 1
      let journalAfter = await vault.storedBytes(journalKey)
      try require(journalAfter == nil,
                  "honest state: the committed removal leaves the journal actually absent")
      checks += 1
      let record = await vault.storedBytes(recordKey(pointerID))
      let descriptor = await vault.storedBytes(descriptorKey(pointerID))
      try require(record == nil && descriptor == nil,
                  "the failed candidate cleanup removes the record and descriptor")
      checks += 1
    }
    return checks
  }

  /// Row 10 of the proof matrix: pointer write failures with a readable/absent
  /// acknowledgment are definitely not committed and are cleaned up with the
  /// original error; an unreadable acknowledgment is a real unknown whose
  /// journal/record/descriptor evidence is retained and never replayed.
  private static func checkPointerPaths(codec: PiliAccountLiveMemoryShadowCodec,
                                        base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let data = try codec.encode(base)
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let initial = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.failPointerWrites(1)
      var surface = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch { surface = isInjected(error) }
      try require(surface,
                  "a pointer write failure with a readable previous(nil) acknowledgment surfaces the original error")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == initial,
                  "definite not-committed cleanup removes candidate/descriptor/journal and leaves no pointer")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 4 && removeAttempts == 3,
                  "definite not-committed path attempts four writes and three cleanup removals")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let expectedJournal = try expectedJournalBytes(attemptedID: pointerID, candidate: data)
      let expectedDescriptor = try manifestBytes(transactionID: pointerID, byteCount: data.count,
                                                 sha256: sha256Hex(data))
      await vault.resetCounters()
      await vault.failPointerWrites(1)
      await vault.failPointerReadsAfter(1)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced = true }
      await vault.allowPointerReads()
      try require(surfaced, "an unreadable pointer acknowledgment is a real publicationUnknown")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter[journalKey] == expectedJournal,
                  "the unknown retains the exact durable journal bytes")
      checks += 1
      try require(snapshotAfter[recordKey(pointerID)] == data,
                  "the unknown retains the candidate record bytes")
      checks += 1
      try require(snapshotAfter[descriptorKey(pointerID)] == expectedDescriptor,
                  "the unknown retains the descriptor bytes")
      checks += 1
      try require(snapshotAfter[manifestKey] == nil, "the failed pointer write leaves no pointer")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 4 && removeAttempts == 0,
                  "the unknown performs no cleanup writes or removes")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let expectedManifest = try manifestBytes(transactionID: pointerID, byteCount: data.count,
                                               sha256: sha256Hex(data))
      await vault.resetCounters()
      await vault.pointerCommitThenThrow(true)
      await vault.failPointerReadsAfter(1)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced = true }
      await vault.allowPointerReads()
      try require(surfaced,
                  "a committed pointer write with an unreadable acknowledgment is publicationUnknown")
      checks += 1
      let pointer = await vault.storedBytes(manifestKey)
      try require(pointer == expectedManifest,
                  "the committed pointer keeps the exact next manifest bytes for later correlation")
      checks += 1
      let journal = await vault.storedBytes(journalKey)
      try require(journal != nil, "the committed-but-unacknowledged attempt keeps its journal")
      checks += 1
    }
    return checks
  }

  /// Row 11 of the proof matrix: a verified commit returns its receipt even
  /// when the journal clear cannot be verified. The journal state is asserted
  /// honestly per fault recipe: a refused remove retains the bytes and keeps
  /// followers fail-closed until an explicit committed classification clears
  /// them; a committed remove whose verification read failed leaves the bytes
  /// actually absent, so there is no durable fence to classify.
  private static func checkVerifiedCommitAndClear(codec: PiliAccountLiveMemoryShadowCodec,
                                                  base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let data = try codec.encode(base)
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let expectedManifest = try manifestBytes(transactionID: pointerID, byteCount: data.count,
                                               sha256: sha256Hex(data))
      await vault.resetCounters()
      await vault.pointerCommitThenThrow(true)
      let receipt = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(receipt.transactionID == pointerID && receipt.recoveredWriteAcknowledgment,
                  "a committed-then-failed pointer write returns the receipt with the recovered flag")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter[manifestKey] == expectedManifest
                  && snapshotAfter[recordKey(pointerID)] == data
                  && snapshotAfter[descriptorKey(pointerID)] == expectedManifest,
                  "the verified commit keeps the exact winner bytes")
      checks += 1
      try require(snapshotAfter[journalKey] == nil,
                  "a verifiable journal clear leaves no journal after a verified commit")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let expectedJournal = try expectedJournalBytes(attemptedID: pointerID, candidate: data)
      await vault.resetCounters()
      await vault.failJournalRemoves(true)
      let receipt = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(receipt.transactionID == pointerID && !receipt.recoveredWriteAcknowledgment,
                  "a refused journal clear still returns the verified-commit receipt")
      checks += 1
      let retained = await vault.storedBytes(journalKey)
      try require(retained == expectedJournal,
                  "the refused remove retains the exact journal bytes")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 4 && removeAttempts == 1,
                  "the retained-journal commit attempts the removal exactly once")
      checks += 1
      let followerStore = PiliAccountEnvelopeTransactionStore(vault: staging)
      let pending = try await followerStore.loadPersistentRecovery()
      try require(pending?.attemptedTransactionID == pointerID && pending?.kind == .bootstrap,
                  "a fresh follower cold-loads the retained evidence as a .bootstrap fence")
      checks += 1
      let journalBeforeBootstrap = await vault.storedBytes(journalKey)
      var blocked = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { blocked = true }
      try require(blocked, "followers stay fail-closed while the receipt's journal is retained")
      checks += 1
      let journalAfterBootstrap = await vault.storedBytes(journalKey)
      try require(journalAfterBootstrap == journalBeforeBootstrap,
                  "the blocked follower never resolves, clears or replays the evidence")
      checks += 1
      var refusedExport = false
      do { _ = try await staging.exportCurrentShadow(expectedTransactionID: pointerID) }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { refusedExport = true }
      try require(refusedExport, "the read-only export refuses the retained fence")
      checks += 1
      await vault.failJournalRemoves(false)
      let resolution = try await followerStore.resolveUnresolvedPublication()
      try require(resolution?.outcome == .attemptCommitted,
                  "the explicit isolated resolution classifies the verified commit as committed")
      checks += 1
      let cleared = await vault.storedBytes(journalKey)
      try require(cleared == nil, "the committed classification clears the journal with verification")
      checks += 1
      let followerID = UUID()
      let follower = try await staging.importShadow(data, expectedTransactionID: pointerID,
                                                   candidateTransactionID: followerID,
                                                   recoveryKind: followerKind)
      try require(follower.transactionID == followerID,
                  "in-contract writes resume after the committed classification")
      checks += 1
      var refusedAgain = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.bootstrapRefused { refusedAgain = true }
      try require(refusedAgain, "a later bootstrap is refused once the pointer exists")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      await vault.resetCounters()
      await vault.failJournalReadAt(3)
      let receipt = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(receipt.transactionID == pointerID,
                  "a committed removal with a failed verification read still returns the receipt")
      checks += 1
      let journalAfter = await vault.storedBytes(journalKey)
      try require(journalAfter == nil,
                  "honest state: the committed removal leaves no retained journal bytes")
      checks += 1
      let followerStore = PiliAccountEnvelopeTransactionStore(vault: staging)
      let pending = try await followerStore.loadPersistentRecovery()
      try require(pending == nil, "with the journal actually absent no durable fence exists")
      checks += 1
      var refusedAgain = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.bootstrapRefused { refusedAgain = true }
      try require(refusedAgain, "the actual state (present pointer, absent journal) refuses bootstrap")
      checks += 1
    }
    return checks
  }

  /// Rows 12-13 of the proof matrix: real cold-load recognition and the three
  /// explicit resolution classifications on isolated fixtures, plus the
  /// normal-path no-auto-resolve guarantee.
  private static func checkColdLoadAndResolution(codec: PiliAccountLiveMemoryShadowCodec,
                                                 base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let data = try codec.encode(base)
    do {
      // Committed fixture: the pointer write committed, its acknowledgment was
      // unreadable, so the retained journal names the exact attempted ID.
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let attemptedID = UUID()
      await vault.pointerCommitThenThrow(true)
      await vault.failPointerReadsAfter(1)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: attemptedID) }
      catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced = true }
      await vault.allowPointerReads()
      try require(surfaced, "committed fixture produced a real publicationUnknown")
      checks += 1
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      let pending = try await store.loadPersistentRecovery()
      try require(pending?.expectedPreviousTransactionID == nil
                  && pending?.attemptedTransactionID == attemptedID
                  && pending?.attemptedCandidateSHA256 == sha256Hex(data)
                  && pending?.kind == .bootstrap,
                  "fresh cold load recognizes the exact .bootstrap evidence fields")
      checks += 1
      let journalBefore = await vault.storedBytes(journalKey)
      try require(journalBefore != nil, "cold load never auto-resolves the journal")
      checks += 1
      let resolution = try await store.resolveUnresolvedPublication()
      try require(resolution?.outcome == .attemptCommitted
                  && resolution?.observedTransactionID == attemptedID,
                  "explicit resolution correlates the exact committed operation identity")
      checks += 1
      let cleared = await vault.storedBytes(journalKey)
      try require(cleared == nil, "the committed classification clears the journal")
      checks += 1
      let again = try await store.resolveUnresolvedPublication()
      try require(again == nil, "the released store no longer has a pending resolution")
      checks += 1
    }
    do {
      // Not-committed fixture: the pointer write failed and its acknowledgment
      // was unreadable, so the pointer remains absent (== expected previous).
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let attemptedID = UUID()
      await vault.failPointerWrites(1)
      await vault.failPointerReadsAfter(1)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: attemptedID) }
      catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced = true }
      await vault.allowPointerReads()
      try require(surfaced, "not-committed fixture produced a real publicationUnknown")
      checks += 1
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      let resolution = try await store.resolveUnresolvedPublication()
      try require(resolution?.outcome == .attemptNotCommitted
                  && resolution?.observedTransactionID == nil,
                  "explicit resolution classifies the unchanged absent pointer as not committed")
      checks += 1
      let cleared = await vault.storedBytes(journalKey)
      try require(cleared == nil, "the not-committed classification clears the journal")
      checks += 1
    }
    do {
      // Ambiguous fixture: the absent-pointer unknown is followed by a foreign
      // pointer (an isolated fixture mutation, not a legal follower).
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let attemptedID = UUID()
      await vault.failPointerWrites(1)
      await vault.failPointerReadsAfter(1)
      var surfaced = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: attemptedID) }
      catch PiliAccountEnvelopeStagingError.publicationUnknown { surfaced = true }
      await vault.allowPointerReads()
      try require(surfaced, "ambiguous fixture produced a real publicationUnknown")
      checks += 1
      let foreignID = UUID()
      let foreignManifest = try manifestBytes(transactionID: foreignID, byteCount: data.count,
                                              sha256: sha256Hex(data))
      await vault.installFixtureBytes(data, key: recordKey(foreignID))
      await vault.installFixtureBytes(foreignManifest, key: manifestKey)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      var ambiguous = false
      do { _ = try await store.resolveUnresolvedPublication() }
      catch PiliAccountShadowTransactionError.ambiguousRecovery { ambiguous = true }
      try require(ambiguous, "a foreign pointer requires the explicit ambiguity acknowledgment")
      checks += 1
      let stillArmed = await store.pendingUnresolvedPublication
      let journalAfterRefusal = await vault.storedBytes(journalKey)
      try require(stillArmed?.attemptedTransactionID == attemptedID && journalAfterRefusal != nil,
                  "the refused ambiguous resolution keeps both fences exactly armed")
      checks += 1
      let resolution = try await store.resolveUnresolvedPublication(allowAmbiguous: true)
      try require(resolution?.outcome == .ambiguousObservedCandidate
                  && resolution?.observedTransactionID == foreignID,
                  "the explicit acknowledgment records the exact ambiguous classification")
      checks += 1
      let cleared = await vault.storedBytes(journalKey)
      try require(cleared == nil, "the acknowledged ambiguity clears the journal")
      checks += 1
    }
    do {
      // Normal-path no-auto-resolve: a fresh store observing valid bootstrap
      // evidence fails a real in-contract publication closed and leaves the
      // journal untouched. The journal is installed after the legal raw
      // publication so the schema-2 pointer exists and adoption reaches the
      // real publication choke point.
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      try await staging.importShadow(data)
      let attemptedID = UUID()
      let journalBytes = try expectedJournalBytes(attemptedID: attemptedID, candidate: data)
      await vault.installFixtureBytes(journalBytes, key: journalKey)
      let store = PiliAccountEnvelopeTransactionStore(vault: staging)
      var blocked = false
      do { _ = try await store.adoptMissingIdentities() }
      catch PiliAccountEnvelopeStagingError.unresolvedRecovery { blocked = true }
      try require(blocked, "a normal in-contract publication fails closed on live evidence")
      checks += 1
      let preserved = await vault.storedBytes(journalKey)
      try require(preserved == journalBytes, "the normal path never auto-resolves the evidence")
      checks += 1
    }
    return checks
  }

  /// Row 13 first half: while a bootstrap holds the shared-vault operation
  /// fence, a second bootstrap and a correlated import are refused with the
  /// established immediate operationInProgress; after release the pointer
  /// exists and create-only refuses.
  private static func checkSameVaultContention(codec: PiliAccountLiveMemoryShadowCodec,
                                               base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let vault = BootstrapFaultVault()
    let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
    let data = try codec.encode(base)
    let firstID = UUID()
    await vault.resetCounters()
    await vault.pauseJournalReadAt(1)
    let outcome = try await runControlledBootstrap(
      label: "contention", vault: vault, staging: staging, input: data,
      candidateTransactionID: firstID, cancelBeforeResume: false
    ) {
      var bootstrapBlocked = false
      do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
      catch PiliAccountEnvelopeStagingError.operationInProgress { bootstrapBlocked = true }
      try require(bootstrapBlocked, "a second same-vault bootstrap meets the operation fence")
      var importBlocked = false
      do {
        _ = try await staging.importShadow(data, expectedTransactionID: UUID(),
                                           candidateTransactionID: UUID(),
                                           recoveryKind: followerKind)
      } catch PiliAccountEnvelopeStagingError.operationInProgress { importBlocked = true }
      try require(importBlocked, "a correlated import meets the same operation fence")
      let pointerDuring = await vault.storedBytes(manifestKey)
      try require(pointerDuring == nil, "rejected writers leave the pointer untouched")
      return 3
    }
    checks += outcome.checks
    try require(outcome.value.transactionID == firstID,
                "the paused create-only publication resumes and publishes its own ID")
    checks += 1
    let journalAfter = await vault.storedBytes(journalKey)
    let pointerAfter = await vault.storedBytes(manifestKey)
    try require(journalAfter == nil && pointerAfter != nil,
                "the resumed bootstrap completes cleanly with the pointer published")
    checks += 1
    await vault.resetCounters()
    var refusedAgain = false
    do { _ = try await staging.bootstrapShadow(data, candidateTransactionID: UUID()) }
    catch PiliAccountEnvelopeStagingError.bootstrapRefused { refusedAgain = true }
    try require(refusedAgain, "after release a new create-only attempt is refused")
    checks += 1
    return checks
  }

  /// Row 7 and the §2.3 cancellation rows: a pre-cancelled task performs zero
  /// IO; cancelling while a read is paused and explicitly resuming surfaces the
  /// exact CancellationError instead of the resumed result's interpretation,
  /// with the defined checkpoint cleanup and no invented rollback.
  private static func checkCancellation(codec: PiliAccountLiveMemoryShadowCodec,
                                        base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let data = try codec.encode(base)
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      let task = Task<PiliAccountEnvelopeStagingReceipt, any Error> {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      }
      var cancelled = false
      do { _ = try await task.value } catch is CancellationError { cancelled = true }
      try require(cancelled, "pre-cancelled bootstrap throws CancellationError before any IO")
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
      let cleanup = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(cleanup.transactionID == pointerID, "fence released after pre-cancel")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.pauseJournalReadAt(1)
      var cancelled = false
      do {
        _ = try await runControlledBootstrap(
          label: "journal-read-cancel", vault: vault, staging: staging, input: data,
          candidateTransactionID: pointerID, cancelBeforeResume: true) { 0 }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "journal-stage cancel surfaces the exact CancellationError")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0,
                  "journal-stage cancel performs no writes or removes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "journal-stage cancel preserves every vault byte")
      checks += 1
      let cleanup = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(cleanup.transactionID == pointerID, "fence released after journal-stage cancel")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.pauseJournalReadAt(2)
      var cancelled = false
      do {
        _ = try await runControlledBootstrap(
          label: "record-checkpoint-cancel", vault: vault, staging: staging, input: data,
          candidateTransactionID: pointerID, cancelBeforeResume: true) { 0 }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "cancel before the record checkpoint surfaces the original CancellationError")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore,
                  "candidate cleanup restores the pre-attempt state after the checkpoint cancel")
      checks += 1
      let cleanup = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(cleanup.transactionID == pointerID, "fence released after checkpoint cancel")
      checks += 1
    }
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let snapshotBefore = await vault.storedSnapshot()
      await vault.resetCounters()
      await vault.pauseManifestReadOnce()
      var cancelled = false
      do {
        _ = try await runControlledBootstrap(
          label: "manifest-cancel", vault: vault, staging: staging, input: data,
          candidateTransactionID: pointerID, cancelBeforeResume: true) { 0 }
      } catch is CancellationError { cancelled = true }
      try require(cancelled, "cancel across the manifest read surfaces CancellationError, not a stale outcome")
      checks += 1
      let writeAttempts = await vault.writeAttemptCount()
      let removeAttempts = await vault.removeAttemptCount()
      try require(writeAttempts == 0 && removeAttempts == 0,
                  "manifest-stage cancel performs no writes or removes")
      checks += 1
      let snapshotAfter = await vault.storedSnapshot()
      try require(snapshotAfter == snapshotBefore, "manifest-stage cancel preserves every vault byte")
      checks += 1
      let cleanup = try await staging.bootstrapShadow(data, candidateTransactionID: pointerID)
      try require(cleanup.transactionID == pointerID, "fence released after manifest-stage cancel")
      checks += 1
    }
    return checks
  }

  /// The controlled-await helper must report every terminal result: a completed
  /// bootstrap (success or failure) is discriminated immediately instead of
  /// leaving the phase wait hanging.
  private static func checkTerminalReporting(codec: PiliAccountLiveMemoryShadowCodec,
                                             base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    do {
      let vault = BootstrapFaultVault()
      let staging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let pointerID = UUID()
      let task = startBootstrapTask(vault: vault, staging: staging, input: try codec.encode(base),
                                    candidateTransactionID: pointerID)
      let paused = await vault.waitUntilPhaseOrTerminal()
      try require(!paused, "completed bootstrap is reported terminal, not an endless wait")
      checks += 1
      let outcome = await vault.terminalOutcome()
      try require(outcome == "success", "early success is reported as success")
      checks += 1
      let value = try await task.value
      try require(value.transactionID == pointerID, "early success keeps the result")
      checks += 1
    }
    do {
      let (_, _, _, adopted) = try await makeAdoptedVault(codec: codec, base: base)
      let vault = BootstrapFaultVault()
      let failureStaging = PiliAccountEnvelopeStagingStore(secrets: vault)
      let task = startBootstrapTask(vault: vault, staging: failureStaging,
                                    input: try codec.encode(adopted.envelope),
                                    candidateTransactionID: UUID())
      let paused = await vault.waitUntilPhaseOrTerminal()
      try require(!paused, "failed bootstrap is reported terminal, not an endless wait")
      checks += 1
      let outcome = await vault.terminalOutcome()
      try require(outcome == "failure", "early failure is reported as failure")
      checks += 1
      var surfaced = false
      do { _ = try await task.value }
      catch PiliAccountEnvelopeStagingError.invalidBootstrap { surfaced = true }
      try require(surfaced, "early failure keeps the exact typed outcome")
      checks += 1
    }
    return checks
  }

  private static func replacingIdentity(_ record: PiliAccountLiveMemoryRecord,
                                        identity: PiliCookieUTF16?) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: record.jar, durableIdentity: identity)
  }

  private static func replacingMid(_ record: PiliAccountLiveMemoryRecord,
                                   mid: Int64) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
  }

  private static func replacingStorageKey(_ record: PiliAccountLiveMemoryRecord,
                                          units: PiliCookieUTF16?) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: units,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
  }

  private static func replacingRecords(_ envelope: PiliAccountLiveMemoryShadow,
                                       records: [PiliAccountLiveMemoryRecord]) -> PiliAccountLiveMemoryShadow {
    PiliAccountLiveMemoryShadow(
      schemaVersion: envelope.schemaVersion, scope: envelope.scope,
      identityScope: envelope.identityScope, revision: envelope.revision,
      durableIdentityConfigured: envelope.durableIdentityConfigured,
      durabilityVerified: envelope.durabilityVerified,
      authoritySwitchAllowed: envelope.authoritySwitchAllowed,
      nativeWritesAllowed: envelope.nativeWritesAllowed, records: records,
      storedOrder: envelope.storedOrder, ownerOrder: envelope.ownerOrder,
      selectionPurposes: envelope.selectionPurposes, selections: envelope.selections,
      history: envelope.history, generationHighWater: envelope.generationHighWater)
  }

  private static func identity(units: [UInt16]) -> PiliCookieUTF16 {
    PiliCookieUTF16(units: units)
  }

  /// The association oracle: positive validation against the independent
  /// capture plus the typed negative rows, all without any vault write.
  private static func checkAssociationOracle(codec: PiliAccountLiveMemoryShadowCodec,
                                             base: PiliAccountLiveMemoryShadow) async throws -> Int {
    var checks = 0
    let (vault, staging, _, _) = try await makeAdoptedVault(codec: codec, base: base)
    guard let current = try await staging.loadShadowSnapshot() else {
      throw BootstrapFixtureError.failed("missing adopted snapshot")
    }
    let export = try await staging.exportCurrentShadow(expectedTransactionID: current.transactionID)
    let exported = try codec.decode(export.envelopeBytes)
    let oracle = ExportAssociationFixtureOracle(codec: codec)
    try oracle.validate(capture: base, exported: exported, pointer: export.transactionID,
                        envelopeSHA256: export.envelopeSHA256, captureRevision: base.revision)
    checks += 1
    try require(current.transactionID == export.transactionID,
                "export is pinned to the actual current pointer")
    checks += 1
    let candidate = try await staging.loadPublishedCandidate(transactionID: export.transactionID)
    try require(candidate == exported,
                "the pointer-named published candidate equals the exported envelope")
    checks += 1
    let labels = exported.records.compactMap(\.durableIdentity)
    try require(labels.count == exported.records.count - 1
                && Set(labels).count == labels.count
                && labels.allSatisfy(PiliAccountLiveMemoryShadow.isCanonicalDurableIdentity),
                "adopted labels are canonical and unique per login record")
    checks += 1
    let highWater = base.records.dropFirst().map(\.generation).max() ?? 0
    try require(exported.effectiveGenerationHighWater == highWater,
                "adopted high-water equals the independent capture maximum")
    checks += 1
    await vault.resetCounters()
    var negatives = 0
    do {
      var records = exported.records
      records[1] = replacingIdentity(records[1], identity: nil)
      var rejected = false
      do {
        try oracle.validate(capture: base, exported: replacingRecords(exported, records: records),
                            pointer: export.transactionID,
                            envelopeSHA256: export.envelopeSHA256,
                            captureRevision: base.revision)
      } catch { rejected = true }
      try require(rejected, "a missing login label is rejected")
      negatives += 1
    }
    do {
      var records = exported.records
      let upper = identity(units: labels[0].units.map { $0 >= 0x61 && $0 <= 0x66 ? $0 - 0x20 : $0 })
      records[1] = replacingIdentity(records[1], identity: upper)
      var rejected = false
      do {
        try oracle.validate(capture: base, exported: replacingRecords(exported, records: records),
                            pointer: export.transactionID,
                            envelopeSHA256: export.envelopeSHA256,
                            captureRevision: base.revision)
      } catch { rejected = true }
      try require(rejected, "a non-canonical label is rejected")
      negatives += 1
    }
    do {
      var records = exported.records
      records[2] = replacingIdentity(records[2], identity: labels[0])
      var rejected = false
      do {
        try oracle.validate(capture: base, exported: replacingRecords(exported, records: records),
                            pointer: export.transactionID,
                            envelopeSHA256: export.envelopeSHA256,
                            captureRevision: base.revision)
      } catch { rejected = true }
      try require(rejected, "duplicate labels are rejected")
      negatives += 1
    }
    do {
      var records = exported.records
      records[1] = replacingMid(records[1], mid: records[1].mid &+ 1)
      var rejected = false
      do {
        try oracle.validate(capture: base, exported: replacingRecords(exported, records: records),
                            pointer: export.transactionID,
                            envelopeSHA256: export.envelopeSHA256,
                            captureRevision: base.revision)
      } catch { rejected = true }
      try require(rejected, "a mid mismatch against the capture is rejected")
      negatives += 1
    }
    do {
      var records = exported.records
      records[1] = replacingStorageKey(records[1], units: nil)
      var rejected = false
      do {
        try oracle.validate(capture: base, exported: replacingRecords(exported, records: records),
                            pointer: export.transactionID,
                            envelopeSHA256: export.envelopeSHA256,
                            captureRevision: base.revision)
      } catch { rejected = true }
      try require(rejected, "a storage-key mismatch against the capture is rejected")
      negatives += 1
    }
    do {
      var rejected = false
      do {
        try oracle.validate(capture: base, exported: exported, pointer: export.transactionID,
                            envelopeSHA256: String(repeating: "0", count: 64),
                            captureRevision: base.revision)
      } catch { rejected = true }
      try require(rejected, "a digest mismatch is rejected")
      negatives += 1
    }
    do {
      var rejected = false
      do {
        try oracle.validate(capture: base, exported: exported, pointer: export.transactionID,
                            envelopeSHA256: export.envelopeSHA256,
                            captureRevision: base.revision &+ 1)
      } catch { rejected = true }
      try require(rejected, "a capture revision mismatch is rejected")
      negatives += 1
    }
    checks += negatives
    let writeAttempts = await vault.writeAttemptCount()
    let removeAttempts = await vault.removeAttemptCount()
    try require(writeAttempts == 0 && removeAttempts == 0,
                "oracle negatives perform zero vault writes/removes")
    checks += 1
    return checks
  }

  /// Rows 14-15 and the real cross-runtime artifacts: a real Keychain create-
  /// only bootstrap, adoption, pinned export and the same-process new-instance
  /// reopen (explicitly not a process-kill proof).
  private static func checkActualKeychainArtifacts(
    codec: PiliAccountLiveMemoryShadowCodec, base: PiliAccountLiveMemoryShadow,
    metadataPath: String, wirePath: String, sourceSHA: String, workflowSHA: String
  ) async throws -> Int {
    var checks = 0
    let namespace = UUID()
    let vault = PiliAccountEnvelopeStagingStore(
      secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace))
    let store = PiliAccountEnvelopeTransactionStore(vault: vault)
    let data = try codec.encode(base)
    let p0ID = UUID()
    let bootstrap = try await vault.bootstrapShadow(data, candidateTransactionID: p0ID)
    try require(bootstrap.transactionID == p0ID && !bootstrap.recoveredWriteAcknowledgment,
                "real Keychain create-only bootstrap publishes the exact operation ID")
    checks += 1
    guard let p0 = try await vault.loadShadowSnapshot() else {
      throw BootstrapFixtureError.failed("missing real-Keychain bootstrap pointer")
    }
    try require(p0.transactionID == p0ID && p0.envelope == base,
                "real pointer P0 is the exact schema-2 bootstrap publication")
    checks += 1
    let adoption = try await store.adoptMissingIdentities()
    try require(adoption.transactionID != nil && adoption.transactionID != p0ID,
                "adoption publishes a new schema-3 pointer P1 != P0")
    checks += 1
    try require(adoption.adopted == base.records.count - 1
                && adoption.adoptedIdentities.count == adoption.adopted
                && adoption.adoptedIdentities.allSatisfy(
                  PiliAccountLiveMemoryShadow.isCanonicalDurableIdentity),
                "adoption mints one canonical label per login record")
    checks += 1
    guard let p1 = try await vault.loadShadowSnapshot() else {
      throw BootstrapFixtureError.failed("missing adopted real-Keychain pointer")
    }
    try require(p1.envelope.schemaVersion == 3,
                "the actual current pointer envelope is schema 3")
    checks += 1
    let secondAdoption = try await store.adoptMissingIdentities()
    try require(secondAdoption.transactionID == nil && secondAdoption.adopted == 0
                && secondAdoption.adoptedIdentities.isEmpty,
                "a schema-3 second adoption is a nil-pointer no-op")
    checks += 1
    let export = try await vault.exportCurrentShadow(expectedTransactionID: p1.transactionID)
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
    let oracle = ExportAssociationFixtureOracle(codec: codec)
    try oracle.validate(capture: base, exported: decoded, pointer: export.transactionID,
                        envelopeSHA256: digest, captureRevision: base.revision)
    checks += 1
    let workflowValue: Any = workflowSHA.isEmpty ? NSNull() : workflowSHA
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
    let reopenedStore = PiliAccountEnvelopeTransactionStore(vault: reopenedVault)
    let reopenedPending = try await reopenedStore.loadPersistentRecovery()
    try require(reopenedPending == nil, "the clean reopened namespace has no pending fence")
    checks += 1
    let reopenedP0 = try await reopenedVault.loadPublishedCandidate(transactionID: p0ID)
    try require(reopenedP0 == base,
                "same-process new instance reads the exact P0 candidate bytes")
    checks += 1
    let reopened = try await reopenedVault.exportCurrentShadow(expectedTransactionID: export.transactionID)
    try require(reopened.envelopeBytes == export.envelopeBytes,
                "same-process Keychain reopen keeps the exact bytes")
    checks += 1
    try require(reopened.envelopeSHA256 == digest, "same-process Keychain reopen keeps the digest")
    checks += 1
    let reopenedAdoption = try await reopenedStore.adoptMissingIdentities()
    try require(reopenedAdoption.transactionID == nil && reopenedAdoption.adopted == 0,
                "the reopened instance sees the adopted schema-3 no-op")
    checks += 1
    return checks
  }

  static func main() async throws {
    guard CommandLine.arguments.count == 6 else {
      throw BootstrapFixtureError.failed(
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
      throw BootstrapFixtureError.failed("actual Dart envelope missing")
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let codec = PiliAccountLiveMemoryShadowCodec()
    let base = try codec.decode(data)
    try require(base.schemaVersion == 2, "the actual Dart golden is a schema-2 envelope")
    try require(base.records.count == 3, "expected anonymous + two login records")
    var checks = try checkKindLiteralMatch()
    checks += try await checkBootstrapBasics(codec: codec, base: base)
    checks += try await checkJournalFences(codec: codec, base: base)
    checks += try await checkCandidateFailures(codec: codec, base: base)
    checks += try await checkPointerPaths(codec: codec, base: base)
    checks += try await checkVerifiedCommitAndClear(codec: codec, base: base)
    checks += try await checkColdLoadAndResolution(codec: codec, base: base)
    checks += try await checkSameVaultContention(codec: codec, base: base)
    checks += try await checkCancellation(codec: codec, base: base)
    checks += try await checkTerminalReporting(codec: codec, base: base)
    checks += try await checkAssociationOracle(codec: codec, base: base)
    checks += try await checkActualKeychainArtifacts(
      codec: codec, base: base, metadataPath: CommandLine.arguments[2],
      wirePath: CommandLine.arguments[3], sourceSHA: sourceSHA, workflowSHA: workflowSHA)
    print("\(checks) native account envelope bootstrap checks passed")
    print("create-only means the current pointer was absent under the single vault fence; it is "
          + "NOT proof the namespace never published, and orphan history/high-water reset stay "
          + "out of scope; journal-removal uncertainty is asserted per actual fault state "
          + "(retained bytes vs committed remove with a failed verification read); the real-"
          + "Keychain reopen row is a same-process new instance, not a process-kill proof")
  }
}
