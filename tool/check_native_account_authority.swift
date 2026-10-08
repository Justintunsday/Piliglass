import Foundation

private enum AuthorityFixtureError: Error { case failed(String), injected }

private actor AuthorityFaultVault: PiliAccountSecretStore {
  enum Fault: Sendable, Equatable {
    case markerWriteBefore, markerWriteAfter, markerReadAfter, markerRemoveKeep, markerRemoveThenError
  }
  private var values: [String: Data] = [:]
  private var fault: Fault?
  private var markerPublished = false
  private enum Pause: Equatable { case anyWrite, markerRemove, manifestReadback }
  private var pause: Pause?
  private var manifestPublished = false
  private var suspended: CheckedContinuation<Void, Never>?
  private var pauseArrival: CheckedContinuation<Void, Never>?
  private let markerKey = "account-authority-marker-v2"
  private let manifestKey = "account-envelope-shadow-manifest-v2"

  func arm(_ next: Fault) { fault = next; markerPublished = false }
  func pauseWrite() { pause = .anyWrite }
  func pauseMarkerRemove() { pause = .markerRemove }
  func pauseManifestReadback() { pause = .manifestReadback; manifestPublished = false }
  func isPaused() -> Bool { suspended != nil }
  func resume() { suspended?.resume(); suspended = nil }
  func waitUntilPaused() async {
    if suspended != nil { return }
    await withCheckedContinuation { pauseArrival = $0 }
  }
  func snapshot() -> [String: Data] { values }
  func writeRawMarker(_ data: Data) { values[markerKey] = data }
  func dropRecord(_ id: UUID) {
    values.removeValue(forKey: "account-envelope-shadow-v2.\(id.uuidString.lowercased())")
  }
  func writeRawRecord(_ id: UUID, _ bytes: Data) {
    values["account-envelope-shadow-v2.\(id.uuidString.lowercased())"] = bytes
  }
  func dropEnvelopeRecords() {
    for key in values.keys where key != markerKey && key != manifestKey {
      values.removeValue(forKey: key)
    }
  }

  func read(_ key: String) async throws -> Data? {
    if key == manifestKey, manifestPublished, pause == .manifestReadback {
      pause = nil
      await suspend()
    }
    if key == markerKey, markerPublished, fault == .markerReadAfter {
      fault = nil; throw AuthorityFixtureError.injected
    }
    return values[key]
  }

  func write(_ data: Data, key: String) async throws {
    if pause == .anyWrite {
      pause = nil
      await suspend()
    }
    if key == markerKey, fault == .markerWriteBefore {
      fault = nil; throw AuthorityFixtureError.injected
    }
    values[key] = data
    if key == manifestKey { manifestPublished = true }
    if key == markerKey {
      markerPublished = true
      if fault == .markerWriteAfter { fault = nil; throw AuthorityFixtureError.injected }
    }
  }

  func remove(_ key: String) async throws {
    if key == markerKey, pause == .markerRemove {
      pause = nil
      await suspend()
    }
    if key == markerKey, fault == .markerRemoveKeep {
      fault = nil; throw AuthorityFixtureError.injected
    }
    if key == markerKey, fault == .markerRemoveThenError {
      fault = nil; values.removeValue(forKey: key); throw AuthorityFixtureError.injected
    }
    values.removeValue(forKey: key)
  }

  private func suspend() async {
    await withCheckedContinuation {
      suspended = $0
      pauseArrival?.resume()
      pauseArrival = nil
    }
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
    var differentValue = try JSONSerialization.jsonObject(with: canonical) as! [String: Any]
    var differentRecords = differentValue["records"] as! [[String: Any]]
    differentRecords[1]["activated"] = !(differentRecords[1]["activated"] as! Bool)
    differentValue["records"] = differentRecords
    let differentCanonical = try codec.encode(codec.decode(
      JSONSerialization.data(withJSONObject: differentValue, options: [.sortedKeys])))
    let differentEnvelope = try codec.decode(differentCanonical)
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

    // The operation gate fences reentry while the first candidate write awaits.
    let fencedVault = AuthorityFaultVault()
    let fencedCoordinator = PiliAccountAuthorityCoordinator(
      vault: PiliAccountEnvelopeStagingStore(secrets: fencedVault),
      markers: PiliAccountAuthorityMarkerStore(secrets: fencedVault))
    await fencedVault.pauseWrite()
    let pending = Task { try await fencedCoordinator.beginHandoff(candidate: canonical, epoch: UUID()) }
    await fencedVault.waitUntilPaused()
    do {
      _ = try await fencedCoordinator.resume()
      throw AuthorityFixtureError.failed("reentrant authority read admitted")
    } catch PiliAccountAuthorityError.operationInProgress { checks += 1 }
    await fencedVault.resume()
    _ = try await pending.value
    try check(try await fencedCoordinator.resume() == base, "fenced handoff publishes once")

    // The authority UUID must resolve its own immutable candidate, even when a
    // later shadow has the same revision and different account state.
    try check(differentEnvelope != base && differentEnvelope.revision == base.revision,
              "same revision fixture has genuinely different content")
    let bindingSecrets = AuthorityFaultVault()
    let bindingVault = PiliAccountEnvelopeStagingStore(secrets: bindingSecrets)
    let bindingMarkers = PiliAccountAuthorityMarkerStore(secrets: bindingSecrets)
    let bindingCoordinator = PiliAccountAuthorityCoordinator(vault: bindingVault, markers: bindingMarkers)
    let bindingReceipt = try await bindingCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
    _ = try await bindingVault.importShadow(differentCanonical)
    try check(try await bindingVault.loadShadow() == differentEnvelope, "shadow advances independently")
    try check(try await bindingCoordinator.resume() == base, "marker resumes its exact older transaction")
    try check(try await bindingCoordinator.reverseExport() == canonical, "reverse export binds exact transaction")
    try await bindingVault.discardShadow()
    try check(try await bindingCoordinator.resume() == base, "shadow discard cannot delete authority candidate")

    // A second handoff cannot change Native authority, including when its
    // marker write would fail. Rejection must happen before any durable write.
    let beforeReplacement = await bindingSecrets.snapshot()
    await bindingSecrets.arm(.markerWriteBefore)
    do {
      _ = try await bindingCoordinator.beginHandoff(candidate: differentCanonical, epoch: UUID())
      throw AuthorityFixtureError.failed("already Native handoff admitted")
    } catch PiliAccountAuthorityError.unsafeState { checks += 1 }
    try check(await bindingSecrets.snapshot() == beforeReplacement, "rejected replacement preserves durable bytes")
    try check(try await bindingCoordinator.resume() == base, "rejected replacement preserves old authority")
    await bindingSecrets.writeRawRecord(bindingReceipt.transactionID, differentCanonical)
    do {
      _ = try await bindingCoordinator.resume()
      throw AuthorityFixtureError.failed("authority accepted record differing from immutable digest")
    } catch PiliAccountEnvelopeStagingError.verificationFailed { checks += 1 }
    await bindingSecrets.writeRawRecord(bindingReceipt.transactionID, canonical)
    try check(try await bindingCoordinator.resume() == base, "restored exact bytes match immutable digest")
    await bindingSecrets.dropRecord(bindingReceipt.transactionID)
    do {
      _ = try await bindingCoordinator.resume()
      throw AuthorityFixtureError.failed("missing named record substituted another same-revision record")
    } catch PiliAccountAuthorityError.missingCandidate { checks += 1 }

    let wrongIDSecrets = AuthorityFaultVault()
    let wrongIDVault = PiliAccountEnvelopeStagingStore(secrets: wrongIDSecrets)
    let wrongIDCoordinator = PiliAccountAuthorityCoordinator(
      vault: wrongIDVault, markers: PiliAccountAuthorityMarkerStore(secrets: wrongIDSecrets))
    _ = try await wrongIDVault.importShadow(canonical)
    await wrongIDSecrets.writeRawMarker(try encodeMarker(PiliAccountAuthorityMarker(
      schemaVersion: 2, authority: .nativeKeychain, phase: .nativeActive, epoch: UUID(),
      candidateTransactionID: UUID(), revision: base.revision)))
    do {
      _ = try await wrongIDCoordinator.resume()
      throw AuthorityFixtureError.failed("unrelated candidate UUID accepted")
    } catch PiliAccountAuthorityError.missingCandidate { checks += 1 }

    // Durable corruption/newer schema/unresolved phases block every handoff,
    // not merely resume. The old marker and vault bytes must remain unchanged.
    let unsafeMarkers = [Data("{}".utf8),
      try encodeMarker(PiliAccountAuthorityMarker(
        schemaVersion: 3, authority: .dartHive, phase: .dartActive, epoch: UUID(),
        candidateTransactionID: nil, revision: 0)),
      try encodeMarker(PiliAccountAuthorityMarker(
        schemaVersion: 2, authority: .nativeKeychain, phase: .transitioning, epoch: UUID(),
        candidateTransactionID: UUID(), revision: base.revision)),
      try encodeMarker(PiliAccountAuthorityMarker(
        schemaVersion: 2, authority: .nativeKeychain, phase: .reverting, epoch: UUID(),
        candidateTransactionID: UUID(), revision: base.revision))]
    for (index, bytes) in unsafeMarkers.enumerated() {
      let secrets = AuthorityFaultVault()
      await secrets.writeRawMarker(bytes)
      let original = await secrets.snapshot()
      let coordinator = PiliAccountAuthorityCoordinator(
        vault: PiliAccountEnvelopeStagingStore(secrets: secrets),
        markers: PiliAccountAuthorityMarkerStore(secrets: secrets))
      do {
        _ = try await coordinator.beginHandoff(candidate: canonical, epoch: UUID())
        throw AuthorityFixtureError.failed("unsafe starting marker admitted")
      } catch PiliAccountAuthorityError.invalidMarker where index < 2 { checks += 1 }
        catch PiliAccountAuthorityError.unsafeState where index >= 2 { checks += 1 }
      try check(await secrets.snapshot() == original, "unsafe handoff performs no durable write")
    }

    // One marker-store fence spans compare/remove/readback. A publication must
    // be rejected while the old clear is suspended, then succeed afterwards.
    let markerSecrets = AuthorityFaultVault()
    let markerStore = PiliAccountAuthorityMarkerStore(secrets: markerSecrets)
    let markerA = PiliAccountAuthorityMarker(schemaVersion: 2, authority: .nativeKeychain,
      phase: .nativeActive, epoch: UUID(), candidateTransactionID: UUID(), revision: 1)
    let markerB = PiliAccountAuthorityMarker(schemaVersion: 2, authority: .nativeKeychain,
      phase: .nativeActive, epoch: UUID(), candidateTransactionID: UUID(), revision: 1)
    _ = try await markerStore.publish(markerA)
    await markerSecrets.pauseMarkerRemove()
    let clearing = Task { try await markerStore.clear(ifMatches: markerA) }
    await markerSecrets.waitUntilPaused()
    do {
      _ = try await markerStore.publish(markerB)
      throw AuthorityFixtureError.failed("publish reentered suspended clear")
    } catch PiliAccountAuthorityError.operationInProgress { checks += 1 }
    do {
      _ = try await markerStore.load()
      throw AuthorityFixtureError.failed("load observed unfinished marker operation")
    } catch PiliAccountAuthorityError.operationInProgress { checks += 1 }
    await markerSecrets.resume()
    try await clearing.value
    try check(try await markerStore.load() == nil, "fenced clear completes before next publication")
    _ = try await markerStore.publish(markerB)
    try check(try await markerStore.load() == markerB, "next publication survives old clear")

    // Cancellation after shadow publication but before authority publication
    // must not turn a cancelled handoff into a new Native authority.
    let cancelledSecrets = AuthorityFaultVault()
    let cancelledVault = PiliAccountEnvelopeStagingStore(secrets: cancelledSecrets)
    let cancelledCoordinator = PiliAccountAuthorityCoordinator(
      vault: cancelledVault, markers: PiliAccountAuthorityMarkerStore(secrets: cancelledSecrets))
    await cancelledSecrets.pauseManifestReadback()
    let cancelled = Task {
      try await cancelledCoordinator.beginHandoff(candidate: canonical, epoch: UUID())
    }
    await cancelledSecrets.waitUntilPaused()
    cancelled.cancel()
    await cancelledSecrets.resume()
    do {
      _ = try await cancelled.value
      throw AuthorityFixtureError.failed("cancelled handoff published Native authority")
    } catch is CancellationError { checks += 1 }
    try check(try await cancelledCoordinator.resume() == nil, "cancelled handoff keeps Dart authority")
    try check(try await cancelledVault.loadShadow() == base, "published shadow remains readable after cancellation")
    print("\(checks) native account authority checks passed")
  }
}
