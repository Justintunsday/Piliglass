import Foundation

struct PiliAccountAuthorityHandoffReceipt: Sendable, Equatable {
  let epoch: UUID
  let transactionID: UUID
  /// The vault or marker write reported failure but its reread confirmed the
  /// durable value. Authority is only claimed after that reread.
  let recoveredWriteAcknowledgment: Bool
}

/// Durable authority coordinator. The caller owns writer freeze/drain before
/// `beginHandoff` and the Dart-side durable import between `reverseExport` and
/// `completeRevert`; this actor owns the single publish point and the crash
/// recovery rules. It never writes account data itself.
/// Composition owns one coordinator, marker actor and shared vault per namespace.
///
/// Recovery: a missing marker means Dart authority. A corrupt, newer-schema or
/// transitioning/reverting marker fails closed. A published Native marker whose
/// vault record cannot be read also fails closed; old Hive state is never used
/// as a silent fallback.
actor PiliAccountAuthorityCoordinator {
  private let vault: PiliAccountEnvelopeStagingStore
  private let markers: PiliAccountAuthorityMarkerStore
  private let codec: PiliAccountLiveMemoryShadowCodec
  private var operationInProgress = false
  var nativeWritesAllowed: Bool { false }

  init(vault: PiliAccountEnvelopeStagingStore, markers: PiliAccountAuthorityMarkerStore,
       limits: PiliOrderedCookieArchiveLimits = .standard) {
    self.vault = vault
    self.markers = markers
    codec = PiliAccountLiveMemoryShadowCodec(limits: limits)
  }

  /// Publishes a frozen candidate and the Native authority marker. The frozen
  /// candidate is durable before the marker can reference it. If the marker
  /// publication result is unknown, this throws; `resume()` decides the
  /// durable truth instead of retrying the handoff.
  @discardableResult
  func beginHandoff(candidate: Data, epoch: UUID) async throws -> PiliAccountAuthorityHandoffReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    // Validate durable authority before any candidate mutation. A handoff is
    // exclusively Dart -> Native; unresolved or already Native state requires
    // recovery/revert, not a second publication over its old pointer.
    if let current = try await markers.load() {
      guard current.authority == .dartHive, current.phase == .dartActive else {
        throw PiliAccountAuthorityError.unsafeState
      }
    }
    let envelope = try codec.decode(candidate)
    let canonical = try codec.encode(envelope)
    let publication = try await vault.importShadow(canonical)
    try Task.checkCancellation()
    let marker = try PiliAccountAuthorityMarker(
      schemaVersion: 2, authority: .nativeKeychain, phase: .nativeActive, epoch: epoch,
      candidateTransactionID: publication.transactionID, revision: envelope.revision).validated()
    let published = try await markers.publish(marker)
    return .init(epoch: published.marker.epoch, transactionID: publication.transactionID,
                 recoveredWriteAcknowledgment: published.recoveredWriteAcknowledgment
                   || publication.recoveredWriteAcknowledgment)
  }

  /// Returns the durable Native envelope only when the marker actually proves
  /// Native authority. A nil result means Dart authority (also after a failed
  /// pre-publication handoff).
  func resume() async throws -> PiliAccountLiveMemoryShadow? {
    try beginOperation()
    defer { operationInProgress = false }
    guard let marker = try await markers.load() else { return nil }
    switch marker.phase {
    case .dartActive:
      return nil
    case .nativeActive:
      let envelope = try await durableEnvelope(marker)
      guard envelope.revision == marker.revision else {
        throw PiliAccountAuthorityError.unsafeState
      }
      return envelope
    case .transitioning, .reverting:
      // A crash while switching cannot silently choose either side.
      throw PiliAccountAuthorityError.unsafeState
    }
  }

  /// Returns the complete reverse-import payload (the validated schema 2
  /// envelope) without changing authority. Reverting stays reversible and
  /// idempotent until `completeRevert` publishes Dart authority.
  func reverseExport() async throws -> Data {
    try beginOperation()
    defer { operationInProgress = false }
    guard let marker = try await markers.load(), marker.phase == .nativeActive else {
      throw PiliAccountAuthorityError.unsafeState
    }
    let envelope = try await durableEnvelope(marker)
    guard envelope.revision == marker.revision else { throw PiliAccountAuthorityError.unsafeState }
    return try codec.encode(envelope)
  }

  /// Single switch back to Dart authority. The caller must have durably
  /// consumed `reverseExport` first. Readback of the marker decides success;
  /// unknown results are resolved from the durable marker at the next launch.
  func completeRevert() async throws {
    try beginOperation()
    defer { operationInProgress = false }
    guard let marker = try await markers.load(), marker.phase == .nativeActive else {
      throw PiliAccountAuthorityError.unsafeState
    }
    try await markers.clear(ifMatches: marker)
  }

  private func durableEnvelope(_ marker: PiliAccountAuthorityMarker) async throws -> PiliAccountLiveMemoryShadow {
    do {
      guard let transactionID = marker.candidateTransactionID else {
        throw PiliAccountAuthorityError.missingCandidate
      }
      return try await vault.loadPublishedCandidate(transactionID: transactionID)
    } catch PiliAccountEnvelopeStagingError.missingRecord {
      throw PiliAccountAuthorityError.missingCandidate
    }
  }

  private func beginOperation() throws {
    // Actor methods can reenter across awaits; fence the load/import/publish
    // sequence until its durable publication has finished.
    guard !operationInProgress else { throw PiliAccountAuthorityError.operationInProgress }
    operationInProgress = true
  }
}
