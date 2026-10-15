import CryptoKit
import Foundation

enum PiliAccountEnvelopeStagingError: Error, Sendable, Equatable {
  case operationInProgress, invalidManifest, missingRecord, verificationFailed, publicationUnknown,
       staleTransaction, invalidRecoveryJournal, unresolvedRecovery, staleRecoveryJournal
}

struct PiliAccountEnvelopeStagingReceipt: Sendable, Equatable {
  let transactionID: UUID
  /// The pointer was reread successfully even though its write reported failure.
  let recoveredWriteAcknowledgment: Bool
}

struct PiliAccountEnvelopeSnapshot: Sendable, Equatable {
  let transactionID: UUID
  let envelope: PiliAccountLiveMemoryShadow
}

/// Persistent evidence that one correlated publication attempt may have an
/// unknown outcome in this namespace. The attempted transaction ID is the
/// operation identity; the candidate digest is content evidence only and never
/// proves that the attempt committed. The journal is single-slot: a correlated
/// publication must not start while another attempt is unresolved, so a
/// same-key follower cannot erase the evidence.
struct PiliAccountEnvelopeRecoveryJournal: Sendable, Equatable {
  let attemptedTransactionID: UUID
  let expectedPreviousTransactionID: UUID?
  let attemptedCandidateSHA256: String
  let kind: String

  static let maximumBytes = 4096
  static let journalKey = "account-envelope-recovery-journal-v1"

  /// Canonical bounded encoding (sorted keys, explicit null for the expected
  /// previous pointer). Decoding rejects any non-canonical byte form, so
  /// truncation or field tampering fails closed instead of reading as absent.
  static func encode(_ journal: PiliAccountEnvelopeRecoveryJournal) throws -> Data {
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "state": "unresolved",
      "attemptedTransactionID": journal.attemptedTransactionID.uuidString.lowercased(),
      "expectedPreviousTransactionID":
        journal.expectedPreviousTransactionID?.uuidString.lowercased() as Any? ?? NSNull(),
      "attemptedCandidateSHA256": journal.attemptedCandidateSHA256,
      "kind": journal.kind,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    guard data.count <= maximumBytes else {
      throw PiliAccountEnvelopeStagingError.invalidRecoveryJournal
    }
    return data
  }

  static func decode(_ data: Data) throws -> PiliAccountEnvelopeRecoveryJournal {
    guard data.count <= maximumBytes,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == keys,
          object["schemaVersion"] as? Int == 1,
          object["state"] as? String == "unresolved",
          let attemptedText = object["attemptedTransactionID"] as? String,
          let attemptedID = canonicalUUID(attemptedText),
          let digestText = object["attemptedCandidateSHA256"] as? String,
          isCanonicalSHA256(digestText),
          let kind = object["kind"] as? String,
          !kind.isEmpty, kind.utf16.count <= 64,
          kind.utf8.allSatisfy({ $0 >= 0x21 && $0 < 0x7F }) else {
      throw PiliAccountEnvelopeStagingError.invalidRecoveryJournal
    }
    let expected: UUID?
    if object["expectedPreviousTransactionID"] is NSNull {
      expected = nil
    } else if let expectedText = object["expectedPreviousTransactionID"] as? String,
              let expectedID = canonicalUUID(expectedText) {
      expected = expectedID
    } else {
      throw PiliAccountEnvelopeStagingError.invalidRecoveryJournal
    }
    let journal = PiliAccountEnvelopeRecoveryJournal(
      attemptedTransactionID: attemptedID,
      expectedPreviousTransactionID: expected,
      attemptedCandidateSHA256: digestText, kind: kind)
    guard try encode(journal) == data else {
      throw PiliAccountEnvelopeStagingError.invalidRecoveryJournal
    }
    return journal
  }

  private static let keys: Set<String> = [
    "schemaVersion", "state", "attemptedTransactionID",
    "expectedPreviousTransactionID", "attemptedCandidateSHA256", "kind",
  ]

  private static func canonicalUUID(_ text: String) -> UUID? {
    guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text else {
      return nil
    }
    return value
  }

  private static func isCanonicalSHA256(_ text: String) -> Bool {
    text.count == 64 && text.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
}

/// Complete capture-local account shadow vault. It has no durable account
/// identity, request authority or live writer. Composition owns one actor per
/// isolated Keychain namespace. Records are immutable; the single manifest is
/// the shadow publication boundary. Published records and their digest descriptors
/// remain immutable: an independent authority marker may still reference them.
/// Namespace-wide orphan collection is deliberately deferred until every durable
/// reference can be accounted for. All composers share this same vault actor.
actor PiliAccountEnvelopeStagingStore {
  private struct Manifest: Codable, Sendable {
    let schemaVersion: Int
    let transactionID: UUID
    let byteCount: Int
    let sha256: String
  }

  private let secrets: any PiliAccountSecretStore
  private let codec: PiliAccountLiveMemoryShadowCodec
  private let manifestKey = "account-envelope-shadow-manifest-v2"
  private var operationInProgress = false
  var nativeWritesAllowed: Bool { false }

  init(secrets: any PiliAccountSecretStore, limits: PiliOrderedCookieArchiveLimits = .standard) {
    self.secrets = secrets
    codec = PiliAccountLiveMemoryShadowCodec(limits: limits)
  }

  @discardableResult
  func importShadow(_ input: Data) async throws -> PiliAccountEnvelopeStagingReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    return try await publishShadow(input, expectedTransactionID: nil)
  }

  /// Compare and publish under the same vault operation fence. All transaction
  /// actors in one namespace must share this vault instance, not separate actors.
  /// When the caller supplies `candidateTransactionID` and `recoveryKind`, this
  /// publication is minted under that exact immutable operation ID (rejecting a
  /// collision with an existing record) and participates in the namespace
  /// recovery journal, so an unknown acknowledgment can be correlated by
  /// identity across a process restart instead of by content.
  @discardableResult
  func importShadow(_ input: Data, expectedTransactionID: UUID,
                    candidateTransactionID: UUID? = nil,
                    recoveryKind: String? = nil) async throws
    -> PiliAccountEnvelopeStagingReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    return try await publishShadow(input, expectedTransactionID: expectedTransactionID,
                                   candidateTransactionID: candidateTransactionID,
                                   recoveryKind: recoveryKind)
  }

  private func publishShadow(_ input: Data, expectedTransactionID: UUID?,
                             candidateTransactionID: UUID? = nil,
                             recoveryKind: String? = nil) async throws
    -> PiliAccountEnvelopeStagingReceipt {
    // Validate and own a complete copy before any persistent mutation.
    let candidate = try codec.decode(input)
    let data = try codec.encode(candidate)
    // Correlated publications participate in the single-slot recovery journal:
    // they require both the exact operation ID and its kind, and they must not
    // start while another attempt in this namespace is unresolved. The raw
    // uncorrelated import stays an out-of-contract primitive whose use during a
    // pending recovery yields honest foreign-pointer ambiguity instead of
    // erasing the journal.
    if candidateTransactionID != nil {
      guard recoveryKind != nil else {
        throw PiliAccountEnvelopeStagingError.verificationFailed
      }
      guard try await recoveryJournal() == nil else {
        throw PiliAccountEnvelopeStagingError.unresolvedRecovery
      }
    }
    let previous = try await manifest()
    if let expectedTransactionID, previous?.value.transactionID != expectedTransactionID {
      throw PiliAccountEnvelopeStagingError.staleTransaction
    }
    try Task.checkCancellation()
    let id = candidateTransactionID ?? UUID()
    let recordKey = key(id)
    if candidateTransactionID != nil {
      // A caller-supplied operation ID must never overwrite an existing record.
      guard try await secrets.read(recordKey) == nil else {
        throw PiliAccountEnvelopeStagingError.verificationFailed
      }
    }
    // Write the durable recovery evidence before the candidate record, the
    // descriptor and the pointer, and only after a verified clean pre-check.
    var journalBytes: Data? = nil
    if let candidateTransactionID, let recoveryKind {
      let journal = PiliAccountEnvelopeRecoveryJournal(
        attemptedTransactionID: candidateTransactionID,
        expectedPreviousTransactionID: expectedTransactionID,
        attemptedCandidateSHA256: digest(data), kind: recoveryKind)
      journalBytes = try PiliAccountEnvelopeRecoveryJournal.encode(journal)
      try await writeRecoveryJournalVerifying(journalBytes!)
    }
    if let previous {
      // Upgrade an existing manifest-only candidate before moving its shadow
      // pointer. A pre-upgrade authority marker may still name that record.
      try await ensureDescriptor(previous)
    }
    let next = Manifest(schemaVersion: 2, transactionID: id, byteCount: data.count, sha256: digest(data))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let nextBytes = try encoder.encode(next)
    do {
      try Task.checkCancellation()
      try await secrets.write(data, key: recordKey)
      guard let copied = try await secrets.read(recordKey), copied == data,
            try codec.decode(copied) == candidate else {
        throw PiliAccountEnvelopeStagingError.verificationFailed
      }
      try await secrets.write(nextBytes, key: descriptorKey(id))
      guard try await secrets.read(descriptorKey(id)) == nextBytes else {
        throw PiliAccountEnvelopeStagingError.verificationFailed
      }
      try Task.checkCancellation()
    } catch {
      // No pointer can refer to this candidate yet; a candidate-stage failure
      // must not leave an unverifiable journal behind.
      try? await secrets.remove(recordKey)
      try? await secrets.remove(descriptorKey(id))
      try await clearJournalAfterFailedAttempt(journalBytes: journalBytes)
      throw error
    }
    var writeFailure: (any Error)?
    do { try await secrets.write(nextBytes, key: manifestKey) }
    catch { writeFailure = error }

    // A failed acknowledgment does not prove that a local Keychain write did
    // not commit. Never delete a record while its pointer may be published,
    // and never clear the journal while the pointer outcome is unknown.
    let observed: Data?
    do { observed = try await secrets.read(manifestKey) }
    catch { throw PiliAccountEnvelopeStagingError.publicationUnknown }
    if observed != nextBytes {
      if let writeFailure, observed == previous?.bytes {
        // Definite not-committed: the pointer still names the previous
        // candidate, so the orphan is removed and the journal is cleared with
        // verification (failure keeps it and fails closed).
        try? await secrets.remove(recordKey)
        try? await secrets.remove(descriptorKey(id))
        try await clearJournalAfterFailedAttempt(journalBytes: journalBytes)
        throw writeFailure
      }
      throw PiliAccountEnvelopeStagingError.publicationUnknown
    }
    // Verified commit: release the journal. A clear that cannot be verified
    // leaves the journal for later recovery classification; the returned
    // receipt is not fabricated because the pointer acknowledgment is the
    // commit proof, and the leftover journal (if any) is classified committed
    // on the next resolution.
    if journalBytes != nil {
      try? await removeRecoveryJournalVerifying()
    }
    return .init(transactionID: id, recoveredWriteAcknowledgment: writeFailure != nil)
  }

  /// Read-only recovery evidence for this namespace. Nil means a clean
  /// namespace; a present-but-corrupt or unreadable journal throws and fails
  /// closed instead of reading as absent.
  func loadRecoveryJournal() async throws -> PiliAccountEnvelopeRecoveryJournal? {
    try beginOperation()
    defer { operationInProgress = false }
    return try await recoveryJournal()
  }

  /// Durable release of the recovery fence for the exact attempted operation.
  /// Nil journal is a no-op; a different token throws instead of clearing newer
  /// evidence; the removal is verified by read-back.
  func clearRecoveryJournal(expectedAttemptedTransactionID: UUID) async throws {
    try beginOperation()
    defer { operationInProgress = false }
    guard let current = try await recoveryJournal() else { return }
    guard current.attemptedTransactionID == expectedAttemptedTransactionID else {
      throw PiliAccountEnvelopeStagingError.staleRecoveryJournal
    }
    try await removeRecoveryJournalVerifying()
  }

  private func recoveryJournal() async throws -> PiliAccountEnvelopeRecoveryJournal? {
    guard let bytes = try await secrets.read(PiliAccountEnvelopeRecoveryJournal.journalKey) else {
      return nil
    }
    return try PiliAccountEnvelopeRecoveryJournal.decode(bytes)
  }

  /// Verified removal: the journal may only be considered released when the
  /// read-back confirms it is gone; otherwise the namespace stays unresolved.
  private func removeRecoveryJournalVerifying() async throws {
    try await secrets.remove(PiliAccountEnvelopeRecoveryJournal.journalKey)
    guard try await secrets.read(PiliAccountEnvelopeRecoveryJournal.journalKey) == nil else {
      throw PiliAccountEnvelopeStagingError.unresolvedRecovery
    }
  }

  /// Writes the single-slot journal and verifies the exact bytes. Any
  /// uncertainty (a failed write whose read-back is present or unreadable, or a
  /// mismatched read-back) is classified as unresolved recovery, never as a
  /// clean namespace; only a verified clear restores the definite state.
  private func writeRecoveryJournalVerifying(_ bytes: Data) async throws {
    let key = PiliAccountEnvelopeRecoveryJournal.journalKey
    do {
      try await secrets.write(bytes, key: key)
    } catch {
      var observed: Data?
      do { observed = try await secrets.read(key) }
      catch {
        try? await secrets.remove(key)
        guard (try? await secrets.read(key)) == nil else {
          throw PiliAccountEnvelopeStagingError.unresolvedRecovery
        }
        throw error
      }
      guard observed != nil else {
        // Definite: the journal never committed and no publication started.
        throw error
      }
      // The journal may exist despite the failed write; publication has not
      // started, but the evidence must be resolved before later writes.
      try? await secrets.remove(key)
      guard (try? await secrets.read(key)) == nil else {
        throw PiliAccountEnvelopeStagingError.unresolvedRecovery
      }
      throw error
    }
    guard let copied = try? await secrets.read(key), copied == bytes else {
      try? await secrets.remove(key)
      guard (try? await secrets.read(key)) == nil else {
        throw PiliAccountEnvelopeStagingError.unresolvedRecovery
      }
      throw PiliAccountEnvelopeStagingError.verificationFailed
    }
  }

  /// A candidate-stage failure proves the pointer was not written. Best-effort
  /// cleanup must still not leave an unverifiable journal: if the journal
  /// cannot be confirmed gone, fail closed with `unresolvedRecovery` so the
  /// caller resolves it by read-back.
  private func clearJournalAfterFailedAttempt(journalBytes: Data?) async throws {
    guard journalBytes != nil else { return }
    do {
      try await removeRecoveryJournalVerifying()
    } catch {
      throw PiliAccountEnvelopeStagingError.unresolvedRecovery
    }
  }

  func loadShadow() async throws -> PiliAccountLiveMemoryShadow? {
    guard let snapshot = try await loadShadowSnapshot() else { return nil }
    return snapshot.envelope
  }

  func loadShadowSnapshot() async throws -> PiliAccountEnvelopeSnapshot? {
    try beginOperation()
    defer { operationInProgress = false }
    guard let current = try await manifest() else { return nil }
    return .init(transactionID: current.value.transactionID,
                 envelope: try await readRecord(current.value))
  }

  /// Resolves the exact immutable candidate named by an authority marker,
  /// independently of a later shadow manifest or its removal.
  func loadPublishedCandidate(transactionID: UUID) async throws -> PiliAccountLiveMemoryShadow {
    try beginOperation()
    defer { operationInProgress = false }
    let descriptor: Manifest
    if let bytes = try await secrets.read(descriptorKey(transactionID)) {
      descriptor = try decodeManifest(bytes)
      guard descriptor.transactionID == transactionID else {
        throw PiliAccountEnvelopeStagingError.invalidManifest
      }
    } else {
      // Existing schema-2 shadows used only the manifest. They can be restored
      // if that manifest still names the exact requested transaction; never
      // substitute another candidate merely because its revision is equal.
      guard let current = try await manifest(), current.value.transactionID == transactionID else {
        throw PiliAccountEnvelopeStagingError.missingRecord
      }
      descriptor = current.value
    }
    return try await readRecord(descriptor)
  }

  private func readRecord(_ descriptor: Manifest) async throws -> PiliAccountLiveMemoryShadow {
    guard let data = try await secrets.read(key(descriptor.transactionID)) else {
      throw PiliAccountEnvelopeStagingError.missingRecord
    }
    guard data.count == descriptor.byteCount, digest(data) == descriptor.sha256 else {
      throw PiliAccountEnvelopeStagingError.verificationFailed
    }
    return try codec.decode(data)
  }

  func discardShadow() async throws {
    try beginOperation()
    defer { operationInProgress = false }
    guard let previous = try await manifest() else { return }
    try await ensureDescriptor(previous)
    var failure: (any Error)?
    do { try await secrets.remove(manifestKey) }
    catch { failure = error }
    let remaining: Data?
    do { remaining = try await secrets.read(manifestKey) }
    catch { throw PiliAccountEnvelopeStagingError.publicationUnknown }
    guard remaining == nil else {
      if let failure { throw failure }
      throw PiliAccountEnvelopeStagingError.publicationUnknown
    }
    // Removing the shadow pointer does not prove that authority has released
    // this candidate. Retain all published records/descriptors until safe GC.
  }

  private func manifest() async throws -> (value: Manifest, bytes: Data)? {
    guard let bytes = try await secrets.read(manifestKey) else { return nil }
    return (try decodeManifest(bytes), bytes)
  }

  private func ensureDescriptor(_ current: (value: Manifest, bytes: Data)) async throws {
    let descriptor = descriptorKey(current.value.transactionID)
    if let existing = try await secrets.read(descriptor) {
      guard existing == current.bytes else {
        throw PiliAccountEnvelopeStagingError.verificationFailed
      }
    } else {
      _ = try await readRecord(current.value)
      try await secrets.write(current.bytes, key: descriptor)
      guard try await secrets.read(descriptor) == current.bytes else {
        throw PiliAccountEnvelopeStagingError.verificationFailed
      }
    }
  }

  private func decodeManifest(_ bytes: Data) throws -> Manifest {
    guard bytes.count <= 4096 else { throw PiliAccountEnvelopeStagingError.invalidManifest }
    let value: Manifest
    do { value = try JSONDecoder().decode(Manifest.self, from: bytes) }
    catch { throw PiliAccountEnvelopeStagingError.invalidManifest }
    guard value.schemaVersion == 2, value.byteCount > 0,
          value.byteCount <= 16 * 1024 * 1024, value.sha256.count == 64,
          value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw PiliAccountEnvelopeStagingError.invalidManifest
    }
    return value
  }

  private func key(_ id: UUID) -> String { "account-envelope-shadow-v2.\(id.uuidString.lowercased())" }

  private func descriptorKey(_ id: UUID) -> String {
    "account-envelope-shadow-descriptor-v2.\(id.uuidString.lowercased())"
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func beginOperation() throws {
    // Actor methods can reenter across awaits; explicitly fence an import,
    // restart read or discard until its local vault operation has finished.
    guard !operationInProgress else { throw PiliAccountEnvelopeStagingError.operationInProgress }
    operationInProgress = true
  }
}
