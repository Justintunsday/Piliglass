import CryptoKit
import Foundation

enum PiliAccountEnvelopeStagingError: Error, Sendable, Equatable {
  case operationInProgress, invalidManifest, missingRecord, verificationFailed, publicationUnknown
}

struct PiliAccountEnvelopeStagingReceipt: Sendable, Equatable {
  let transactionID: UUID
  /// The pointer was reread successfully even though its write reported failure.
  let recoveredWriteAcknowledgment: Bool
}

/// Complete capture-local account shadow vault. It has no durable account
/// identity, request authority or live writer. Composition owns one actor per
/// isolated Keychain namespace. Records are immutable; the single manifest is
/// the only publication boundary, so no reader can observe a partial write.
actor PiliAccountEnvelopeStagingStore {
  private struct Manifest: Codable {
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
    // Validate and own a complete copy before any persistent mutation.
    let candidate = try codec.decode(input)
    let data = try codec.encode(candidate)
    let previous = try await manifest()
    let id = UUID()
    let recordKey = key(id)
    do {
      try Task.checkCancellation()
      try await secrets.write(data, key: recordKey)
      guard let copied = try await secrets.read(recordKey), copied == data,
            try codec.decode(copied) == candidate else {
        throw PiliAccountEnvelopeStagingError.verificationFailed
      }
      try Task.checkCancellation()
    } catch {
      // No pointer can refer to this candidate yet.
      try? await secrets.remove(recordKey)
      throw error
    }

    let next = Manifest(schemaVersion: 2, transactionID: id, byteCount: data.count, sha256: digest(data))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let nextBytes = try encoder.encode(next)
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
        throw writeFailure
      }
      throw PiliAccountEnvelopeStagingError.publicationUnknown
    }
    if let previous {
      // Publication and reread completed. Failed cleanup leaves only an
      // unreferenced shadow record, never a dangling live pointer.
      try? await secrets.remove(key(previous.value.transactionID))
    }
    return .init(transactionID: id, recoveredWriteAcknowledgment: writeFailure != nil)
  }

  func loadShadow() async throws -> PiliAccountLiveMemoryShadow? {
    try beginOperation()
    defer { operationInProgress = false }
    guard let current = try await manifest() else { return nil }
    guard let data = try await secrets.read(key(current.value.transactionID)) else {
      throw PiliAccountEnvelopeStagingError.missingRecord
    }
    guard data.count == current.value.byteCount, digest(data) == current.value.sha256 else {
      throw PiliAccountEnvelopeStagingError.verificationFailed
    }
    return try codec.decode(data)
  }

  func discardShadow() async throws {
    try beginOperation()
    defer { operationInProgress = false }
    guard let previous = try await manifest() else { return }
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
    try await secrets.remove(key(previous.value.transactionID))
  }

  private func manifest() async throws -> (value: Manifest, bytes: Data)? {
    guard let bytes = try await secrets.read(manifestKey) else { return nil }
    guard bytes.count <= 4096 else { throw PiliAccountEnvelopeStagingError.invalidManifest }
    let value: Manifest
    do { value = try JSONDecoder().decode(Manifest.self, from: bytes) }
    catch { throw PiliAccountEnvelopeStagingError.invalidManifest }
    guard value.schemaVersion == 2, value.byteCount > 0,
          value.byteCount <= 16 * 1024 * 1024, value.sha256.count == 64,
          value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw PiliAccountEnvelopeStagingError.invalidManifest
    }
    return (value, bytes)
  }

  private func key(_ id: UUID) -> String { "account-envelope-shadow-v2.\(id.uuidString.lowercased())" }

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
