import CryptoKit
import Foundation

enum PiliAccountEnvelopeStagingError: Error, Sendable, Equatable {
  case operationInProgress, invalidManifest, missingRecord, verificationFailed, publicationUnknown, staleTransaction
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
  @discardableResult
  func importShadow(_ input: Data, expectedTransactionID: UUID) async throws
    -> PiliAccountEnvelopeStagingReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    return try await publishShadow(input, expectedTransactionID: expectedTransactionID)
  }

  private func publishShadow(_ input: Data, expectedTransactionID: UUID?) async throws
    -> PiliAccountEnvelopeStagingReceipt {
    // Validate and own a complete copy before any persistent mutation.
    let candidate = try codec.decode(input)
    let data = try codec.encode(candidate)
    let previous = try await manifest()
    if let expectedTransactionID, previous?.value.transactionID != expectedTransactionID {
      throw PiliAccountEnvelopeStagingError.staleTransaction
    }
    try Task.checkCancellation()
    if let previous {
      // Upgrade an existing manifest-only candidate before moving its shadow
      // pointer. A pre-upgrade authority marker may still name that record.
      try await ensureDescriptor(previous)
    }
    let id = UUID()
    let recordKey = key(id)
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
      // No pointer can refer to this candidate yet.
      try? await secrets.remove(recordKey)
      try? await secrets.remove(descriptorKey(id))
      throw error
    }
    var writeFailure: (any Error)?
    do { try await secrets.write(nextBytes, key: manifestKey) }
    catch { writeFailure = error }

    // A failed acknowledgment does not prove that a local Keychain write did
    // not commit. Never delete a record while its pointer may be published.
    let observed: Data?
    do { observed = try await secrets.read(manifestKey) }
    catch { throw PiliAccountEnvelopeStagingError.publicationUnknown }
    if observed != nextBytes {
      if let writeFailure, observed == previous?.bytes {
        try? await secrets.remove(recordKey)
        try? await secrets.remove(descriptorKey(id))
        throw writeFailure
      }
      throw PiliAccountEnvelopeStagingError.publicationUnknown
    }
    return .init(transactionID: id, recoveredWriteAcknowledgment: writeFailure != nil)
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
