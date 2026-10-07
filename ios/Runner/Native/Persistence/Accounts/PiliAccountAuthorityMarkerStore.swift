import Foundation

enum PiliAccountAuthority: String, Codable, Sendable, Equatable {
  case dartHive, nativeKeychain
}

enum PiliAccountAuthorityPhase: String, Codable, Sendable, Equatable {
  case dartActive, transitioning, reverting, nativeActive
}

enum PiliAccountAuthorityError: Error, Sendable, Equatable {
  case operationInProgress, invalidMarker, publicationUnknown, missingCandidate, unsafeState
}

/// Non-secret authority pointer. The live Cookie/Token payload never lives in
/// this record; the marker only names the authority, epoch, phase and the
/// candidate transaction it references.
struct PiliAccountAuthorityMarker: Codable, Sendable, Equatable {
  let schemaVersion: Int
  let authority: PiliAccountAuthority
  let phase: PiliAccountAuthorityPhase
  let epoch: UUID
  let candidateTransactionID: UUID?
  let revision: Int64

  func validated() throws -> Self {
    guard schemaVersion == 2, revision >= 0 else {
      throw PiliAccountAuthorityError.invalidMarker
    }
    switch phase {
    case .dartActive:
      guard authority == .dartHive, candidateTransactionID == nil else {
        throw PiliAccountAuthorityError.invalidMarker
      }
    case .nativeActive:
      guard authority == .nativeKeychain, candidateTransactionID != nil else {
        throw PiliAccountAuthorityError.invalidMarker
      }
    case .transitioning, .reverting:
      guard candidateTransactionID != nil else { throw PiliAccountAuthorityError.invalidMarker }
    }
    return self
  }
}

/// One Keychain namespace hosts exactly one authority marker. Publication is
/// write + readback; a failed write is resolved by reread before any claim.
actor PiliAccountAuthorityMarkerStore {
  private let secrets: any PiliAccountSecretStore
  private let markerKey = "account-authority-marker-v2"

  init(secrets: any PiliAccountSecretStore) {
    self.secrets = secrets
  }

  func load() async throws -> PiliAccountAuthorityMarker? {
    guard let bytes = try await secrets.read(markerKey) else { return nil }
    guard bytes.count <= 4096 else { throw PiliAccountAuthorityError.invalidMarker }
    let marker: PiliAccountAuthorityMarker
    do { marker = try JSONDecoder().decode(PiliAccountAuthorityMarker.self, from: bytes) }
    catch { throw PiliAccountAuthorityError.invalidMarker }
    return try marker.validated()
  }

  @discardableResult
  func publish(_ marker: PiliAccountAuthorityMarker) async throws
    -> (marker: PiliAccountAuthorityMarker, recoveredWriteAcknowledgment: Bool) {
    let marker = try marker.validated()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(marker)
    var writeFailure: (any Error)?
    do { try await secrets.write(bytes, key: markerKey) }
    catch { writeFailure = error }
    let observed: Data?
    do { observed = try await secrets.read(markerKey) }
    catch { throw PiliAccountAuthorityError.publicationUnknown }
    guard observed == bytes else { throw PiliAccountAuthorityError.publicationUnknown }
    return (marker, writeFailure != nil)
  }

  /// Clears the marker only while the observed durable marker is exactly the
  /// expected one. Readback decides success; an unreadable result is unknown.
  func clear(ifMatches expected: PiliAccountAuthorityMarker) async throws {
    guard try await load() == expected else { throw PiliAccountAuthorityError.unsafeState }
    var removeFailure: (any Error)?
    do { try await secrets.remove(markerKey) }
    catch { removeFailure = error }
    let remaining: PiliAccountAuthorityMarker?
    do { remaining = try await load() }
    catch { throw PiliAccountAuthorityError.publicationUnknown }
    if let removeFailure, remaining == nil { return }
    guard remaining == nil else { throw PiliAccountAuthorityError.publicationUnknown }
  }
}
