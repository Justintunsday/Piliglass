import Foundation

private enum AuthorityFixtureError: Error { case failed(String), injected }

private actor AuthorityFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable {
    case markerWriteBefore, markerWriteAfter, markerReadAfter, markerRemoveKeep, markerRemoveThenError
  }
  private var values: [String: Data] = [:]
  private var fault: Fault?
  private var markerPublished = false
  private var pause = false
  private var suspended: CheckedContinuation<Void, Never>?
  private let markerKey = "account-authority-marker-v2"
  private let manifestKey = "account-envelope-shadow-manifest-v2"

  func arm(_ next: Fault) { fault = next; markerPublished = false }
  func pauseWrite() { pause = true }
  func isPaused() -> Bool { suspended != nil }
  func resume() { suspended?.resume(); suspended = nil }
  func writeRawMarker(_ data: Data) { values[markerKey] = data }
  func dropEnvelopeRecords() {
    for key in values.keys where key != markerKey && key != manifestKey {
      values.removeValue(forKey: key)
    }
  }

  func read(_ key: String) throws -> Data? {
    if key == markerKey, markerPublished, fault == .markerReadAfter {
      fault = nil; throw AuthorityFixtureError.injected
    }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    if pause {
      pause = false
      await withCheckedContinuation { suspended = $0 }
    }
    if key == markerKey, fault == .markerWriteBefore {
      fault = nil; throw AuthorityFixtureError.injected
    }
    values[key] = data
    if key == markerKey {
      markerPublished = true
      if fault == .markerWriteAfter { fault = nil; throw AuthorityFixtureError.injected }
    }
  }

  func remove(_ key: String) throws {
    if key == markerKey, fault == .markerRemoveKeep {
      fault = nil; throw AuthorityFixtureError.injected
    }
    if key == markerKey, fault == .markerRemoveThenError {
      fault = nil; values.removeValue(forKey: key); throw AuthorityFixtureError.injected
    }
    values.removeValue(forKey: key)
  }
}

@main private struct AccountAuthorityChecks {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw AuthorityFixtureError.failed("fresh live actual Dart envelope golden required")
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let cases = root["cases"] as? [[String: Any]],
          let value = cases.first(where: { $0["id"] as? String == "stored-10-2-owner-2-10" })?["envelope"] else {
      throw AuthorityFixtureError.failed("actual Dart envelope missing")
    }
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let codec = PiliAccountLiveMemoryShadowCodec()
    let base = try codec.decode(data)
    let canonical = try codec.encode(base)
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
      guard condition else { throw AuthorityFixtureError.failed(label) }
      checks += 1
    }
    func encodeMarker(_ marker: PiliAccountAuthorityMarker) throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return try encoder.encode(marker)
    }

    // Real Security.framework namespace: handoff, restart resume, idempotent
    // reverse export and the single revert switch.
    let namespace = UUID()
    func realCoordinator() -> PiliAccountAuthorityCoordinator {
      let secrets = PiliAccountKeychainSecretStore(stagingNamespace: namespace)
      return PiliAccountAuthorityCoordinator(
        vault: PiliAccountEnvelopeStagingStore(secrets: secrets),
        markers: PiliAccountAuthorityMarkerStore(secrets: secrets))
    }
    do {
      let coordinator = realCoordinator()
      try check(try await coordinator.resume() == nil, "missing marker means Dart authority")
      let epoch = UUID()
      let receipt = try await coordinator.beginHandoff(candidate: canonical, epoch: epoch)
      try check(receipt.epoch == epoch && receipt.recoveredWriteAcknowledgment == false,
                "handoff names the actual epoch without a recovered acknowledgment")
      try check(try await coordinator.resume() == base, "published Native marker resumes actual envelope")
      let restarted = realCoordinator()
      try check(try await restarted.resume() == base, "new coordinator resumes durable authority")
      try check(try await restarted.reverseExport() == canonical, "reverse export is the canonical envelope")
      try check(try await restarted.resume() == base, "reverse export does not switch authority")
      try await restarted.completeRevert()
      try check(try await realCoordinator().resume() == nil, "revert publishes Dart authority")
      let secrets = PiliAccountKeychainSecretStore(stagingNamespace: namespace)
      try check(try await secrets.read("account-authority-marker-v2") == nil, "revert clears the marker")
      _ = try await realCoordinator().beginHandoff(candidate: canonical, epoch: UUID())
      try await realCoordinator().completeRevert()
      try check(try await realCoordinator().resume() == nil, "second handoff and revert are repeatable")
    } catch {
      try? await PiliAccountEnvelopeStagingStore(
        secrets: PiliAccountKeychainSecretStore(stagingNamespace: namespace)).discardShadow()
      throw error
    }

    // Failed marker write before any publication keeps Dart authority even
    // though the shadow candidate is already durable.
    let beforeVault = AuthorityFaultVault()
    let beforeCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: beforeVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: beforeVault))
    await beforeVault.arm(.markerWriteBefore)
    do {
      _ = try await beforeCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
      throw AuthorityFixtureError.failed("failed marker write not surfaced")
    } catch AuthorityFixtureError.injected { checks += 1 }
    try check(try await beforeCoordinator.resume() == nil, "unpublished handoff keeps Dart authority")

    // Write-then-error is resolved by marker reread before authority is claimed.
    let afterVault = AuthorityFaultVault()
    let afterCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: afterVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: afterVault))
    await afterVault.arm(.markerWriteAfter)
    let recovered = try await afterCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
    try check(recovered.recoveredWriteAcknowledgment, "marker write-then-error resolved by reread")
    try check(try await afterCoordinator.resume() == base, "recovered publication is durable Native authority")

    // Unknown readback after a successful marker write: a fresh coordinator
    // must resolve the durable truth instead of the thrown error.
    let unknownVault = AuthorityFaultVault()
    let unknownCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: unknownVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: unknownVault))
    await unknownVault.arm(.markerReadAfter)
    do {
      _ = try await unknownCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
      throw AuthorityFixtureError.failed("unknown marker acknowledgment not surfaced")
    } catch PiliAccountAuthorityError.publicationUnknown { checks += 1 }
    let unknownRestart = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: unknownVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: unknownVault))
    try check(try await unknownRestart.resume() == base, "durable marker decides after unknown acknowledgment")

    // Crash/stale states fail closed and never fall back to old Hive state.
    let corruptionVault = AuthorityFaultVault()
    let corruptionCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: corruptionVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: corruptionVault))
    await corruptionVault.writeRawMarker(Data("{}".utf8))
    do {
      _ = try await corruptionCoordinator.resume()
      throw AuthorityFixtureError.failed("corrupt marker accepted")
    } catch PiliAccountAuthorityError.invalidMarker { checks += 1 }

    for phase in [PiliAccountAuthorityPhase.transitioning, .reverting] {
      let crashVault = AuthorityFaultVault()
      let crashCoordinator = PiliAccountAuthorityCoordinator(
        vault: PiliAccountEnvelopeStagingStore(secrets: crashVault),
        markers: PiliAccountAuthorityMarkerStore(secrets: crashVault))
      await crashVault.writeRawMarker(try encodeMarker(PiliAccountAuthorityMarker(
        schemaVersion: 2, authority: .nativeKeychain, phase: phase, epoch: UUID(),
        candidateTransactionID: UUID(), revision: 0)))
      do {
        _ = try await crashCoordinator.resume()
        throw AuthorityFixtureError.failed("crash phase \(phase.rawValue) silently resolved")
      } catch PiliAccountAuthorityError.unsafeState { checks += 1 }
    }

    let missingVault = AuthorityFaultVault()
    let missingCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: missingVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: missingVault))
    _ = try await missingCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
    await missingVault.dropEnvelopeRecords()
    do {
      _ = try await missingCoordinator.resume()
      throw AuthorityFixtureError.failed("Native marker without candidate silently resolved")
    } catch PiliAccountAuthorityError.missingCandidate { checks += 1 }

    // Revert must not switch when the marker cannot actually be cleared.
    let keepVault = AuthorityFaultVault()
    let keepCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: keepVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: keepVault))
    _ = try await keepCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
    await keepVault.arm(.markerRemoveKeep)
    do {
      try await keepCoordinator.completeRevert()
      throw AuthorityFixtureError.failed("kept marker reported revert success")
    } catch PiliAccountAuthorityError.publicationUnknown { checks += 1 }
    try check(try await keepCoordinator.resume() == base, "kept marker preserves Native authority")

    // A remove that landed despite its error is accepted only after readback.
    let removedVault = AuthorityFaultVault()
    let removedCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: removedVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: removedVault))
    _ = try await removedCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
    await removedVault.arm(.markerRemoveThenError)
    try await removedCoordinator.completeRevert()
    try check(try await removedCoordinator.resume() == nil, "verified marker removal publishes Dart authority")

    // The operation gate fences reentry while the marker write awaits.
    let fencedVault = AuthorityFaultVault()
    let fencedCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: fencedVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: fencedVault))
    await fencedVault.pauseWrite()
    let pending = Task { try await fencedCoordinator.beginHandoff(candidate: canonical, epoch: UUID()) }
    for _ in 0..<1000 {
      if await fencedVault.isPaused() { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    if !(await fencedVault.isPaused()) {
      pending.cancel(); throw AuthorityFixtureError.failed("authority write did not suspend")
    }
    do {
      _ = try await fencedCoordinator.resume()
      throw AuthorityFixtureError.failed("reentrant authority read admitted")
    } catch PiliAccountAuthorityError.operationInProgress { checks += 1 }
    await fencedVault.resume()
    _ = try await pending.value
    try check(try await fencedCoordinator.resume() == base, "fenced handoff publishes once")
    print("\(checks) native account authority checks passed")
  }
}
