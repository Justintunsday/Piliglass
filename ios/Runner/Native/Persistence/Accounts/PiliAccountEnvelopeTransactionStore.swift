import CryptoKit
import Foundation

enum PiliAccountShadowTransactionError: Error, Sendable, Equatable {
  case operationInProgress, shadowUnavailable, unknownRecordKey, staleGeneration
  case duplicateRecordKey, invalidInstall
  case invalidDelete, invalidImport
  case invalidBuvid
  /// The bounded account write FIFO is full; nothing was admitted and nothing
  /// was dropped silently. The caller may retry after the queue drains.
  case writeQueueOverflow
  /// Bounded contention retries (cross-store fence/CAS) were exhausted. No
  /// receipt is fabricated; the caller must read back before deciding.
  case publicationConflict
  /// A previous publication returned `publicationUnknown` and its outcome has
  /// not been resolved by an explicit read-back. Every later durable write
  /// fails closed with this error until `resolveUnresolvedPublication()`
  /// records the read-back; an unknown outcome is never replayed or inferred
  /// from a later payload.
  case unresolvedPublication
  /// A read-back resolution is already in flight. Resolution is single-flight so
  /// a stale resolver can never release a newer fence.
  case resolutionInProgress
  /// The fence this read-back belongs to no longer exists or was replaced; the
  /// stale resolver must not release any fence with its read-back.
  case staleResolution
}

struct PiliAccountShadowCookieSave: Sendable, Equatable {
  let fields: [String]
  let representation: PiliNativeCookieFieldRepresentation
  let location: PiliOrderedCookieResponseLocation
  let nowMicroseconds: Int64
}

/// Complete login record appended by the install transaction. The transaction
/// mints the durable identity itself; callers cannot supply one.
struct PiliAccountShadowInstall: Sendable, Equatable {
  let storageKeyUnits: PiliCookieUTF16
  let mid: Int64
  let generation: Int64
  let accessKeyUnits: PiliCookieUTF16?
  let refreshTokenUnits: PiliCookieUTF16?
  let persistedPurposes: [PiliAccountPurpose]
  let activated: Bool
  let jar: PiliOrderedCookieArchive
}

/// One durable write for the account-level bounded FIFO. Every case names the
/// exact record (storage key + capture-local generation) it requires; the queue
/// revalidates against a fresh snapshot on every attempt, so a queued write can
/// never publish from a snapshot that stopped being current.
enum PiliAccountShadowQueuedWrite: Sendable, Equatable {
  case adoptIdentities
  case install(PiliAccountShadowInstall)
  case importRecords([PiliAccountShadowInstall])
  case delete(recordKey: PiliCookieUTF16, generation: Int64)
  case cookieSave(recordKey: PiliCookieUTF16, generation: Int64,
                  save: PiliAccountShadowCookieSave)
  case cookieDelete(recordKey: PiliCookieUTF16, generation: Int64, host: String,
                    withDomainSharedCookie: Bool)
  case cookieDeleteAll(recordKey: PiliCookieUTF16, generation: Int64)
  case temporarySelection(recordKey: PiliCookieUTF16, generation: Int64,
                          purpose: PiliAccountPurpose)
  case purposeChange(recordKey: PiliCookieUTF16, generation: Int64,
                     purpose: PiliAccountPurpose, previousKey: PiliCookieUTF16?,
                     previousGeneration: Int64?)
  case credentials(recordKey: PiliCookieUTF16, generation: Int64,
                   accessKey: PiliCookieUTF16?, refreshToken: PiliCookieUTF16?)
  case activated(recordKey: PiliCookieUTF16, generation: Int64, activated: Bool)
  case buvidSeed(recordKey: PiliCookieUTF16, generation: Int64,
                 value: PiliCookieUTF16, nowMicroseconds: Int64)
}

/// Tagged result of one queued durable write. Every case carries the underlying
/// transaction receipt with both authority gates false; no case fabricates
/// success for an unknown publication.
enum PiliAccountShadowWriteOutcome: Sendable, Equatable {
  case record(PiliAccountShadowTransactionReceipt)
  case importReceipt(PiliAccountShadowImportReceipt)
  case buvid(PiliAccountShadowBuvidReceipt)
  case identity(PiliAccountShadowIdentityReceipt)
}

struct PiliAccountShadowIdentityReceipt: Sendable, Equatable {
  /// Nil when the envelope already carried identities (no publication).
  let transactionID: UUID?
  let adopted: Int
  /// Identities minted by this adoption in record order (empty on no-op).
  let adoptedIdentities: [PiliCookieUTF16]
  let nativeWritesAllowed: Bool
  let authoritySwitchAllowed: Bool
}

struct PiliAccountShadowImportReceipt: Sendable, Equatable {
  let transactionID: UUID
  let replaced: Int
  let appended: Int
  /// Result identities in input order: a replacement keeps the existing
  /// identity, an append carries the freshly minted one.
  let identities: [PiliCookieUTF16]
  let nativeWritesAllowed: Bool
  let authoritySwitchAllowed: Bool
}

struct PiliAccountShadowBuvidReceipt: Sendable, Equatable {
  /// Nil when the record already carried buvid3 (idempotent no-op).
  let transactionID: UUID?
  let seeded: Bool
  /// The target record's durable identity (nil only for legacy schema-2 input
  /// without one). A durable label, never an authorization.
  let durableIdentity: PiliCookieUTF16?
  let nativeWritesAllowed: Bool
  let authoritySwitchAllowed: Bool
}

struct PiliAccountShadowTransactionReceipt: Sendable, Equatable {
  let transactionID: UUID
  let record: Int
  /// The exact record's persisted identity (nil only for a schema-2/anonymous
  /// target without one). A durable label, never an authorization.
  let durableIdentity: PiliCookieUTF16?
  let nativeWritesAllowed: Bool
  let authoritySwitchAllowed: Bool
}

/// Compact diagnostics for the exact attempted write whose publication result
/// is unknown. It carries no payload for replay.
enum PiliAccountShadowUnresolvedWriteKind: Sendable, Equatable {
  case adoptIdentities, install, importRecords, delete, cookieSave, cookieDelete
  case cookieDeleteAll, temporarySelection, purposeChange, credentials, activated, buvidSeed
}

/// Immutable evidence retained for one unresolved publication: the exact
/// pointer the write tried to replace, the exact immutable transaction ID the
/// attempt would have published under, and the SHA-256 of the exact encoded
/// candidate. The ID is the operation identity used for correlated recovery;
/// the digest is content evidence only and is never treated as proof that the
/// operation committed.
struct PiliAccountShadowUnresolvedPublication: Sendable, Equatable {
  let expectedPreviousTransactionID: UUID?
  let attemptedTransactionID: UUID
  let attemptedCandidateSHA256: String
  let kind: PiliAccountShadowUnresolvedWriteKind
}

/// Correlated classification of one unknown-publication read-back.
enum PiliAccountShadowPublicationResolutionOutcome: Sendable, Equatable {
  /// The published pointer names the exact attempted transaction ID: the
  /// attempt's pointer write is correlated operation identity.
  case attemptCommitted
  /// The published pointer still names the candidate the attempt intended to
  /// replace (including "no candidate before"): the attempt never became the
  /// published candidate, even when its bytes match the current content.
  case attemptNotCommitted
  /// The published pointer names neither the attempted ID nor the expected
  /// previous ID: another publication intervened, so this read-back cannot
  /// classify the attempt either way.
  case ambiguousObservedCandidate
}

/// Recorded read-back outcome that releases the unresolved-publication fence.
/// The `outcome` is derived from exact immutable transaction IDs, never from
/// content equality. `observedContentMatchesAttempt` is reported separately as
/// content-only evidence: a same-value/no-op write can be byte-identical, so a
/// true value must not be used as operation proof. A failed read-back throws
/// and keeps the fence armed; a cancelled or stale resolver never releases a
/// fence it does not own.
struct PiliAccountShadowPublicationResolution: Sendable, Equatable {
  let expectedPreviousTransactionID: UUID?
  let attemptedTransactionID: UUID
  let attemptedCandidateSHA256: String
  let observedTransactionID: UUID?
  let observedCandidateSHA256: String?
  let outcome: PiliAccountShadowPublicationResolutionOutcome
  let observedContentMatchesAttempt: Bool
}

/// Durable single-account transaction over the capture-local shadow. It mutates
/// one exact record (ordered jar, temporary selection, credentials, activated)
/// through production values, revalidates the whole envelope with the shared
/// cumulative ledger and only then publishes a new immutable candidate through
/// the vault pointer.
///
/// This is not an authority handoff: generations stay capture-local, the
/// revision is not renumbered and every receipt states both gates false.
actor PiliAccountEnvelopeTransactionStore {
  private let vault: PiliAccountEnvelopeStagingStore
  private let codec: PiliAccountLiveMemoryShadowCodec
  private var reducer: PiliNativeOrderedCookieReducer
  private var operationInProgress = false
  private let maxPendingWrites: Int
  private let maxQueueAttempts: Int
  private let retryDelayNanoseconds: UInt64
  private var writerActive = false
  private var pendingWrites = 0
  private var waitingTurns: [CheckedContinuation<Void, Never>] = []
  /// True only while a queued turn is actively executing one attempt. Direct
  /// public entry is rejected whenever `writerActive` holds the turn (including
  /// bounded retry back-off and reserved waiters), so a public bypass can never
  /// enter ahead of admitted queue work; queued attempts pass through because
  /// they run inside this flag.
  private var executingQueuedTurn = false
  private var queueRetrySleeps = 0
  private var unresolved: PiliAccountShadowUnresolvedPublication?
  /// Single-flight gate for `resolveUnresolvedPublication()`: a second
  /// concurrent resolver fails closed instead of racing the fence.
  private var resolutionInProgress = false
  var nativeWritesAllowed: Bool { false }
  var authoritySwitchAllowed: Bool { false }

  /// Waiting (not yet executing) writes in the bounded FIFO. Observability for
  /// tests/telemetry; it never admits or drops a write.
  var pendingWriteCount: Int { pendingWrites }
  var writeQueueIdle: Bool { !writerActive && pendingWrites == 0 }
  /// Bounded contention retries that backed off in this store's lifetime.
  /// Observability only; it never admits or drops a write.
  var retrySleepCount: Int { queueRetrySleeps }
  /// Immutable evidence of a `publicationUnknown` whose read-back resolution
  /// has not been recorded yet. While non-nil every durable write fails closed
  /// with `unresolvedPublication`.
  var pendingUnresolvedPublication: PiliAccountShadowUnresolvedPublication? {
    unresolved
  }

  init(vault: PiliAccountEnvelopeStagingStore,
       limits: PiliOrderedCookieArchiveLimits = .standard,
       maxPendingWrites: Int = 32,
       maxQueueAttempts: Int = 40,
       retryDelayNanoseconds: UInt64 = 25_000_000) {
    self.vault = vault
    codec = PiliAccountLiveMemoryShadowCodec(limits: limits)
    reducer = PiliNativeOrderedCookieReducer(limits: limits)
    self.maxPendingWrites = max(1, maxPendingWrites)
    self.maxQueueAttempts = max(1, maxQueueAttempts)
    self.retryDelayNanoseconds = max(0, retryDelayNanoseconds)
  }

  /// Account-level write coordination: one bounded FIFO around the
  /// single-publisher vault. Same-key submissions keep submission order; every
  /// attempt loads a fresh snapshot and revalidates key+generation, so a queued
  /// write can neither lose an intervening update nor publish from a snapshot
  /// that stopped being current (bounded fence/CAS retry; exhausted retries
  /// throw `publicationConflict`). A full queue throws `writeQueueOverflow`
  /// immediately and never silently drops the write. Cancellation before
  /// publication publishes nothing and the FIFO keeps draining.
  ///
  /// `publicationUnknown` always propagates and arms a fail-closed
  /// unresolved-publication fence: no later write, queued or direct, publishes
  /// until `resolveUnresolvedPublication()` records the read-back, so a
  /// same-key follower can never cover the unknown operation's evidence. The
  /// unknown operation itself is never replayed.
  func enqueue(_ write: PiliAccountShadowQueuedWrite) async throws
    -> PiliAccountShadowWriteOutcome {
    try Task.checkCancellation()
    try requireResolvedPublication()
    if writerActive {
      guard pendingWrites < maxPendingWrites else {
        throw PiliAccountShadowTransactionError.writeQueueOverflow
      }
      pendingWrites += 1
      await withCheckedContinuation { waitingTurns.append($0) }
      pendingWrites -= 1
      do {
        try Task.checkCancellation()
        // A previous turn may have armed the fence while this write waited.
        try requireResolvedPublication()
      } catch {
        passTurn()
        throw error
      }
    }
    writerActive = true
    do {
      let outcome = try await executeQueuedWrite(write)
      passTurn()
      return outcome
    } catch {
      passTurn()
      throw error
    }
  }

  /// Read-only durable identity lookup over the current published envelope. No
  /// activation, reconciliation, network or write; nil means the current
  /// candidate has no such identity. Compare with the vault transactionID from
  /// `loadShadowSnapshot()` for cross-restart confirmation.
  func lookupRecord(durableIdentity: PiliCookieUTF16) async throws
    -> PiliAccountLiveMemoryRecord? {
    guard let snapshot = try await vault.loadShadowSnapshot() else { return nil }
    return snapshot.envelope.records.first { $0.durableIdentity == durableIdentity }
  }

  /// Read-only snapshot passthrough used for unknown-publication recovery
  /// decisions (write-after-error means published; write-before-error means
  /// not published).
  func loadShadowSnapshot() async throws -> PiliAccountEnvelopeSnapshot? {
    try await vault.loadShadowSnapshot()
  }

  private func passTurn() {
    writerActive = false
    while !waitingTurns.isEmpty {
      writerActive = true
      waitingTurns.removeFirst().resume()
      return
    }
  }

  /// Single publication choke point. Any `publicationUnknown` first records the
  /// immutable attempted operation evidence (exact transaction ID, expected
  /// previous pointer, content digest) and the fail-closed fence, then
  /// propagates unchanged. The digest is content evidence only; correlated
  /// recovery uses the exact transaction ID.
  private func publishCandidate(_ candidate: PiliAccountLiveMemoryShadow,
                                expectedTransactionID: UUID,
                                kind: PiliAccountShadowUnresolvedWriteKind) async throws
    -> PiliAccountEnvelopeStagingReceipt {
    let data = try codec.encode(candidate)
    // Mint the immutable operation identity before publishing so an unknown
    // acknowledgment can be correlated by exact identity, never by content.
    let attemptID = UUID()
    do {
      return try await vault.importShadow(data, expectedTransactionID: expectedTransactionID,
                                          candidateTransactionID: attemptID)
    } catch PiliAccountEnvelopeStagingError.publicationUnknown {
      if unresolved == nil {
        unresolved = PiliAccountShadowUnresolvedPublication(
          expectedPreviousTransactionID: expectedTransactionID,
          attemptedTransactionID: attemptID,
          attemptedCandidateSHA256: Self.digest(data), kind: kind)
      }
      throw PiliAccountEnvelopeStagingError.publicationUnknown
    }
  }

  /// Fail-closed gate: a durable write may only proceed while no unresolved
  /// publication is waiting for its recorded read-back resolution.
  private func requireResolvedPublication() throws {
    guard unresolved == nil else {
      throw PiliAccountShadowTransactionError.unresolvedPublication
    }
  }

  /// Mandatory read-back for a prior `publicationUnknown`, and the only way the
  /// fence is released. Resolution is single-flight, cancellation-aware and
  /// revalidates the immutable pending-operation token after every await, so a
  /// stale resolver can never release a newer fence. The outcome is correlated
  /// exact operation identity (pointer names the attempted transaction ID) or
  /// unchanged previous pointer or an explicit ambiguity; content equality is
  /// reported separately and is never operation proof. It never replays the
  /// unknown write and never fabricates a receipt for it.
  func resolveUnresolvedPublication() async throws
    -> PiliAccountShadowPublicationResolution? {
    guard let pending = unresolved else { return nil }
    guard !resolutionInProgress else {
      throw PiliAccountShadowTransactionError.resolutionInProgress
    }
    resolutionInProgress = true
    defer { resolutionInProgress = false }
    try Task.checkCancellation()
    let snapshot = try await vault.loadShadowSnapshot()
    try Task.checkCancellation()
    // Revalidate the captured immutable token after every await: a newer fence
    // (or another resolver's completion) must never be released by this
    // read-back.
    guard unresolved?.attemptedTransactionID == pending.attemptedTransactionID else {
      throw PiliAccountShadowTransactionError.staleResolution
    }
    let observedDigest: String?
    if let snapshot {
      observedDigest = Self.digest(try codec.encode(snapshot.envelope))
    } else {
      observedDigest = nil
    }
    let observedID = snapshot?.transactionID
    let outcome: PiliAccountShadowPublicationResolutionOutcome
    if observedID == pending.attemptedTransactionID {
      outcome = .attemptCommitted
    } else if observedID == pending.expectedPreviousTransactionID {
      // The pointer still names the candidate the attempt intended to replace
      // (including "no candidate before"): not committed, even if bytes match.
      outcome = .attemptNotCommitted
    } else {
      outcome = .ambiguousObservedCandidate
    }
    let resolution = PiliAccountShadowPublicationResolution(
      expectedPreviousTransactionID: pending.expectedPreviousTransactionID,
      attemptedTransactionID: pending.attemptedTransactionID,
      attemptedCandidateSHA256: pending.attemptedCandidateSHA256,
      observedTransactionID: observedID,
      observedCandidateSHA256: observedDigest,
      outcome: outcome,
      observedContentMatchesAttempt: observedDigest == pending.attemptedCandidateSHA256)
    unresolved = nil
    return resolution
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func executeQueuedWrite(_ write: PiliAccountShadowQueuedWrite) async throws
    -> PiliAccountShadowWriteOutcome {
    var attempt = 0
    while true {
      attempt += 1
      do {
        // Only the active attempt counts as queued execution: direct public
        // entry stays rejected during the retry back-off below.
        executingQueuedTurn = true
        defer { executingQueuedTurn = false }
        return try await performQueuedWrite(write)
      } catch let error as PiliAccountShadowTransactionError
        where error == .operationInProgress {
        guard attempt < maxQueueAttempts else {
          throw PiliAccountShadowTransactionError.publicationConflict
        }
        queueRetrySleeps += 1
        try await Task.sleep(nanoseconds: retryDelayNanoseconds)
      } catch let error as PiliAccountEnvelopeStagingError
        where error == .operationInProgress || error == .staleTransaction {
        guard attempt < maxQueueAttempts else {
          throw PiliAccountShadowTransactionError.publicationConflict
        }
        queueRetrySleeps += 1
        try await Task.sleep(nanoseconds: retryDelayNanoseconds)
      }
    }
  }

  private func performQueuedWrite(_ write: PiliAccountShadowQueuedWrite) async throws
    -> PiliAccountShadowWriteOutcome {
    switch write {
    case .adoptIdentities:
      return .identity(try await adoptMissingIdentities())
    case .install(let install):
      return .record(try await applyInstall(install))
    case .importRecords(let entries):
      return .importReceipt(try await applyImport(entries))
    case .delete(let recordKey, let generation):
      return .record(try await applyDelete(recordKeyUnits: recordKey,
                                           expectedGeneration: generation))
    case .cookieSave(let recordKey, let generation, let save):
      return .record(try await applyCookieSave(recordKeyUnits: recordKey,
                                               expectedGeneration: generation, save))
    case .cookieDelete(let recordKey, let generation, let host, let shared):
      return .record(try await applyCookieDelete(recordKeyUnits: recordKey,
        expectedGeneration: generation, host: host, withDomainSharedCookie: shared))
    case .cookieDeleteAll(let recordKey, let generation):
      return .record(try await applyCookieDeleteAll(recordKeyUnits: recordKey,
                                                    expectedGeneration: generation))
    case .temporarySelection(let recordKey, let generation, let purpose):
      return .record(try await applyTemporarySelection(recordKeyUnits: recordKey,
        expectedGeneration: generation, purpose: purpose))
    case .purposeChange(let recordKey, let generation, let purpose, let previousKey,
                        let previousGeneration):
      return .record(try await applyPurposeChange(recordKeyUnits: recordKey,
        expectedGeneration: generation, purpose: purpose, previousKeyUnits: previousKey,
        previousExpectedGeneration: previousGeneration))
    case .credentials(let recordKey, let generation, let accessKey, let refreshToken):
      return .record(try await applyCredentials(recordKeyUnits: recordKey,
        expectedGeneration: generation, accessKeyUnits: accessKey,
        refreshTokenUnits: refreshToken))
    case .activated(let recordKey, let generation, let activated):
      return .record(try await applyActivated(recordKeyUnits: recordKey,
                                              expectedGeneration: generation,
                                              activated: activated))
    case .buvidSeed(let recordKey, let generation, let value, let now):
      return .buvid(try await applyBuvidSeed(recordKeyUnits: recordKey,
        expectedGeneration: generation, valueUnits: value, nowMicroseconds: now))
    }
  }

  func applyCookieSave(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                       _ save: PiliAccountShadowCookieSave) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration,
                          kind: .cookieSave) { current, index in
      let jar = try self.reducer.save(current.records[index].jar, fields: save.fields,
                                      representation: save.representation, location: save.location,
                                      nowMicroseconds: save.nowMicroseconds)
      return self.replaceJar(current, index: index, jar: jar)
    }
  }

  func applyCookieDelete(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                         host: String, withDomainSharedCookie: Bool) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration,
                          kind: .cookieDelete) { current, index in
      let jar = try self.reducer.delete(current.records[index].jar, host: host,
                                        withDomainSharedCookie: withDomainSharedCookie)
      return self.replaceJar(current, index: index, jar: jar)
    }
  }

  func applyCookieDeleteAll(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration,
                          kind: .cookieDeleteAll) { current, index in
      let jar = try self.reducer.deleteAll(current.records[index].jar)
      return self.replaceJar(current, index: index, jar: jar)
    }
  }

  /// Temporary selection only changes the effective slot; persisted purposes
  /// and every other record stay untouched. History follows the actual source
  /// policy: a login heartbeat uses its own slot, otherwise main.
  func applyTemporarySelection(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                               purpose: PiliAccountPurpose) async throws
    -> PiliAccountShadowTransactionReceipt {
    // The source order is fixed: main, heartbeat, recommend, video.
    let slot = slotIndex(purpose)
    return try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration,
                                 kind: .temporarySelection) { current, index in
      var selections = current.selections
      selections[slot] = current.records[index].record
      let heartbeat = selections[1]
      let history = current.records[heartbeat].isLogin ? heartbeat : selections[0]
      return self.replace(current, selections: selections, history: history)
    }
  }

  /// Low-level durable purpose move across at most two explicitly named
  /// records. It does NOT scan for other holders and does NOT enforce global
  /// uniqueness: legacy captures (and Dart imports with `preserveTypes:false`)
  /// may hold the same purpose on several records, and only the caller-named
  /// `previousKeyUnits` loses it. Exact preconditions:
  /// - `previousKeyUnits == nil` means "no holder to remove": if another record
  ///   still holds the purpose it keeps it (documented primitive behavior).
  /// - a non-nil previous must name the actual holder; a record that does not
  ///   hold the purpose is left untouched.
  /// - `previousKeyUnits == recordKeyUnits` is an idempotent no-op for removal.
  /// The selected record gains the purpose (idempotent, appended in Dart
  /// insertion order), the slot points at it and history is derived with the
  /// existing policy. Only persistedPurposes, selections and history change;
  /// jars, orders, generations and the capture-local revision stay untouched.
  func applyPurposeChange(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                          purpose: PiliAccountPurpose,
                          previousKeyUnits: PiliCookieUTF16?,
                          previousExpectedGeneration: Int64?) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration,
                          kind: .purposeChange) { current, index in
      var records = current.records
      let selected = records[index]
      if !selected.persistedPurposes.contains(purpose) {
        records[index] = Self.replacingPurposes(
          selected, purposes: selected.persistedPurposes + [purpose])
      }
      if let previousKeyUnits {
        guard let previousExpectedGeneration else {
          throw PiliAccountShadowTransactionError.staleGeneration
        }
        guard let previousIndex = current.records.firstIndex(where: {
          $0.record > 0 && $0.storageKeyUnits == previousKeyUnits
        }) else {
          throw PiliAccountShadowTransactionError.unknownRecordKey
        }
        let previous = records[previousIndex]
        guard previous.generation == previousExpectedGeneration, previous.isLogin else {
          throw PiliAccountShadowTransactionError.staleGeneration
        }
        if previousIndex != index, previous.persistedPurposes.contains(purpose) {
          records[previousIndex] = Self.replacingPurposes(
            previous, purposes: previous.persistedPurposes.filter { $0 != purpose })
        }
      }
      var selections = current.selections
      selections[slotIndex(purpose)] = records[index].record
      let heartbeat = selections[1]
      let history = records[heartbeat].isLogin ? heartbeat : selections[0]
      return self.replace(current, records: records, selections: selections, history: history)
    }
  }

  func applyCredentials(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                        accessKeyUnits: PiliCookieUTF16?, refreshTokenUnits: PiliCookieUTF16?) async throws
    -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration,
                          kind: .credentials) { current, index in
      let record = current.records[index]
      var records = current.records
      records[index] = PiliAccountLiveMemoryRecord(
        record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
        mid: record.mid, isLogin: record.isLogin, accessKeyUnits: accessKeyUnits,
        refreshTokenUnits: refreshTokenUnits, persistedPurposes: record.persistedPurposes,
        activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
      return self.replace(current, records: records)
    }
  }

  func applyActivated(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                      activated: Bool) async throws -> PiliAccountShadowTransactionReceipt {
    try await transaction(recordKeyUnits: recordKeyUnits, expectedGeneration: expectedGeneration,
                          kind: .activated) { current, index in
      let record = current.records[index]
      var records = current.records
      records[index] = PiliAccountLiveMemoryRecord(
        record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
        mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
        refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
        activated: activated, jar: record.jar, durableIdentity: record.durableIdentity)
      return self.replace(current, records: records)
    }
  }

  /// Upgrades a schema-2 envelope to schema 3 by minting one persisted identity
  /// per login record. Already-adopted envelopes are a no-op receipt that does
  /// not publish. Identities are minted exactly once here; nothing derives them
  /// from MID, storage key or runtime generation, and nothing authorizes with
  /// them.
  func adoptMissingIdentities() async throws -> PiliAccountShadowIdentityReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 2 else {
      return .init(transactionID: nil, adopted: 0, adoptedIdentities: [],
                   nativeWritesAllowed: false, authoritySwitchAllowed: false)
    }
    var records = current.records
    var identities = Set<PiliCookieUTF16>()
    for record in records {
      if let identity = record.durableIdentity { identities.insert(identity) }
    }
    var adopted = 0
    var adoptedIdentities: [PiliCookieUTF16] = []
    for index in records.indices where index > 0 {
      let identity = Self.mintIdentity(excluding: identities)
      identities.insert(identity)
      records[index] = Self.replacingIdentity(records[index], identity: identity)
      adoptedIdentities.append(identity)
      adopted += 1
    }
    let highWater = records.dropFirst().map(\.generation).max() ?? 0
    let candidate = replace(current, records: records, schemaVersion: 3,
                            generationHighWater: highWater)
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await publishCandidate(candidate,
                                                 expectedTransactionID: snapshot.transactionID,
                                                 kind: .adoptIdentities)
    return .init(transactionID: publication.transactionID, adopted: adopted,
                 adoptedIdentities: adoptedIdentities,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Appends one complete login record to an adopted (schema-3) envelope. The
  /// transaction mints the record identity and appends the matching stored/
  /// owner order entries; selections, history, anonymous and every existing
  /// record stay untouched.
  func applyInstall(_ install: PiliAccountShadowInstall) async throws
    -> PiliAccountShadowTransactionReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    // Install is append-only on adopted envelopes; a schema-2 envelope must be
    // adopted first so no existing record changes shape silently.
    guard current.schemaVersion == 3,
          !install.storageKeyUnits.units.isEmpty,
          install.generation > 0,
          Set(install.persistedPurposes).count == install.persistedPurposes.count,
          current.records.count + 1 <= 256 else {
      throw PiliAccountShadowTransactionError.invalidInstall
    }
    guard !current.records.contains(where: {
      $0.record > 0 && $0.storageKeyUnits == install.storageKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.duplicateRecordKey
    }
    // A new generation is only accepted above the persisted monotonic
    // high-water, so a generation removed by delete or replaced by import can
    // never be reused, including after a restart.
    let highWater = current.effectiveGenerationHighWater
    guard install.generation > highWater else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    var identities = Set<PiliCookieUTF16>()
    for record in current.records {
      if let identity = record.durableIdentity { identities.insert(identity) }
    }
    let newIndex = current.records.count
    let record = PiliAccountLiveMemoryRecord(
      record: newIndex, generation: install.generation,
      storageKeyUnits: install.storageKeyUnits, mid: install.mid, isLogin: true,
      accessKeyUnits: install.accessKeyUnits, refreshTokenUnits: install.refreshTokenUnits,
      persistedPurposes: install.persistedPurposes, activated: install.activated,
      jar: install.jar, durableIdentity: Self.mintIdentity(excluding: identities))
    let order = PiliAccountLiveMemoryOrderEntry(
      keyUnits: install.storageKeyUnits, record: newIndex)
    let candidate = replace(current,
      records: current.records + [record],
      storedOrder: current.storedOrder + [order],
      ownerOrder: current.ownerOrder + [order],
      generationHighWater: max(highWater, install.generation))
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await publishCandidate(candidate,
                                                 expectedTransactionID: snapshot.transactionID,
                                                 kind: .install)
    return .init(transactionID: publication.transactionID, record: newIndex,
                 durableIdentity: record.durableIdentity,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Deletes one exact login record from an adopted envelope. Records after the
  /// deleted index are renumbered, both orders are removed and renumbered, and
  /// every selection slot follows the Dart delete policy: a slot that pointed
  /// at the deleted record becomes anonymous, later slots shift by one.
  /// History is derived again; remaining record identities are preserved.
  func applyDelete(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64) async throws
    -> PiliAccountShadowTransactionReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 3 else {
      throw PiliAccountShadowTransactionError.invalidDelete
    }
    // Anonymous records carry no storage key, so it can never be matched here.
    guard let index = current.records.firstIndex(where: {
      $0.record > 0 && $0.storageKeyUnits == recordKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.unknownRecordKey
    }
    let deleted = current.records[index]
    guard deleted.generation == expectedGeneration, deleted.isLogin else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    var records: [PiliAccountLiveMemoryRecord] = []
    for (oldIndex, record) in current.records.enumerated() where oldIndex != index {
      let newIndex = oldIndex < index ? oldIndex : oldIndex - 1
      records.append(newIndex == oldIndex ? record : Self.renumbered(record, as: newIndex))
    }
    let storedOrder = current.storedOrder
      .filter { $0.record != index }
      .map { entry in entry.record < index ? entry :
        PiliAccountLiveMemoryOrderEntry(keyUnits: entry.keyUnits, record: entry.record - 1) }
    let ownerOrder = current.ownerOrder
      .filter { $0.record != index }
      .map { entry in entry.record < index ? entry :
        PiliAccountLiveMemoryOrderEntry(keyUnits: entry.keyUnits, record: entry.record - 1) }
    let selections = current.selections.map { slot in
      if slot == index { return 0 }
      return slot > index ? slot - 1 : slot
    }
    let heartbeat = selections[1]
    let history = records[heartbeat].isLogin ? heartbeat : selections[0]
    let candidate = replace(current, records: records, storedOrder: storedOrder,
                            ownerOrder: ownerOrder, selections: selections, history: history)
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await publishCandidate(candidate,
                                                 expectedTransactionID: snapshot.transactionID,
                                                 kind: .delete)
    return .init(transactionID: publication.transactionID, record: index,
                 durableIdentity: deleted.durableIdentity,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Imports complete login records into an adopted envelope, mirroring Dart
  /// `importCredentials`: an input key that already exists replaces that exact
  /// record in place (identity preserved, generation must be genuinely new), a
  /// new key is appended in input order with a minted identity, and the owner
  /// registry/selections/history are rebuilt exactly like Dart's trailing
  /// `refresh()` (temporary selections cleared). One candidate is published;
  /// any rejection publishes nothing.
  func applyImport(_ entries: [PiliAccountShadowInstall]) async throws
    -> PiliAccountShadowImportReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 3 else {
      throw PiliAccountShadowTransactionError.invalidImport
    }
    guard !entries.isEmpty else { throw PiliAccountShadowTransactionError.invalidImport }
    var entryKeys = Set<PiliCookieUTF16>()
    var entryGenerations = Set<Int64>()
    let highWater = current.effectiveGenerationHighWater
    // Key shape and uniqueness first, so a duplicate input key is always
    // reported as duplicateRecordKey regardless of generation arithmetic.
    for entry in entries {
      guard !entry.storageKeyUnits.units.isEmpty,
            Set(entry.persistedPurposes).count == entry.persistedPurposes.count else {
        throw PiliAccountShadowTransactionError.invalidImport
      }
      guard entryKeys.insert(entry.storageKeyUnits).inserted else {
        throw PiliAccountShadowTransactionError.duplicateRecordKey
      }
    }
    // Every imported generation must be genuinely new (above the persisted
    // monotonic high-water) and unique inside the input, so replacement can
    // never reuse a replaced or historically removed generation.
    for entry in entries {
      guard entry.generation > 0, entry.generation > highWater,
            entryGenerations.insert(entry.generation).inserted else {
        throw PiliAccountShadowTransactionError.staleGeneration
      }
    }
    var records = current.records
    var identities = Set<PiliCookieUTF16>()
    for record in records {
      if let identity = record.durableIdentity { identities.insert(identity) }
    }
    var replaced = 0
    var appended = 0
    var appendedOrder: [PiliAccountLiveMemoryOrderEntry] = []
    var resolvedIdentities: [PiliCookieUTF16] = []
    for entry in entries {
      if let index = records.firstIndex(where: {
        $0.record > 0 && $0.storageKeyUnits == entry.storageKeyUnits
      }) {
        records[index] = PiliAccountLiveMemoryRecord(
          record: index, generation: entry.generation,
          storageKeyUnits: entry.storageKeyUnits, mid: entry.mid, isLogin: true,
          accessKeyUnits: entry.accessKeyUnits, refreshTokenUnits: entry.refreshTokenUnits,
          persistedPurposes: entry.persistedPurposes, activated: entry.activated,
          jar: entry.jar, durableIdentity: records[index].durableIdentity)
        guard let identity = records[index].durableIdentity else {
          throw PiliAccountShadowTransactionError.invalidImport
        }
        resolvedIdentities.append(identity)
        replaced += 1
        continue
      }
      guard records.count + 1 <= 256 else {
        throw PiliAccountShadowTransactionError.invalidImport
      }
      let newIndex = records.count
      let identity = Self.mintIdentity(excluding: identities)
      identities.insert(identity)
      records.append(PiliAccountLiveMemoryRecord(
        record: newIndex, generation: entry.generation,
        storageKeyUnits: entry.storageKeyUnits, mid: entry.mid, isLogin: true,
        accessKeyUnits: entry.accessKeyUnits, refreshTokenUnits: entry.refreshTokenUnits,
        persistedPurposes: entry.persistedPurposes, activated: entry.activated,
        jar: entry.jar, durableIdentity: identity))
      resolvedIdentities.append(identity)
      appendedOrder.append(PiliAccountLiveMemoryOrderEntry(
        keyUnits: entry.storageKeyUnits, record: newIndex))
      appended += 1
    }
    // Dart importCredentials ends in refresh(): a replaced owner is revoked and
    // re-inserted at the end of the owner registry, temporary selections are
    // cleared and every slot is rebuilt from owners/types in that order with
    // the last writer winning. Mirror that observable result exactly.
    var ownerOrder = current.ownerOrder.filter { !entryKeys.contains($0.keyUnits) }
    for entry in entries {
      guard let index = records.firstIndex(where: {
        $0.storageKeyUnits == entry.storageKeyUnits
      }) else {
        throw PiliAccountShadowTransactionError.invalidImport
      }
      ownerOrder.append(PiliAccountLiveMemoryOrderEntry(
        keyUnits: entry.storageKeyUnits, record: records[index].record))
    }
    var selections = [0, 0, 0, 0]
    for orderEntry in ownerOrder {
      for purpose in records[orderEntry.record].persistedPurposes {
        selections[slotIndex(purpose)] = orderEntry.record
      }
    }
    let heartbeat = selections[1]
    let history = records[heartbeat].isLogin ? heartbeat : selections[0]
    let candidate = replace(current, records: records,
      storedOrder: current.storedOrder + appendedOrder,
      ownerOrder: ownerOrder, selections: selections, history: history,
      generationHighWater: max(highWater, entryGenerations.max() ?? highWater))
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await publishCandidate(candidate,
                                                 expectedTransactionID: snapshot.transactionID,
                                                 kind: .importRecords)
    return .init(transactionID: publication.transactionID, replaced: replaced, appended: appended,
                 identities: resolvedIdentities,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Maximum caller value accepted before the field is constructed. The raw
  /// Set-Cookie parser ceiling is `maximumValueUnits` (65536) bytes for one
  /// field; 64 units of `"buvid3="`/`"; Domain=.bilibili.com; Path=/"` headroom
  /// stay below it, so this API fails intentionally (`resourceLimit`) instead
  /// of surfacing a parser error. Length and domain are documented in
  /// P05_DURABLE_BUVID_PLAN.md.
  static let buvidMaximumValueUnits =
    PiliOrderedCookieArchiveLimits.standard.maximumValueUnits - 64

  /// Seeds the missing `buvid3` cookie of one exact login record, mirroring
  /// Dart `BiliCookieJar.setBuvid3` (`domainCookies['bilibili.com']['/']
  /// ['buvid3'] ??=`). The value is caller-supplied printable ASCII; the
  /// transaction never mints credentials. An existing buvid3 is an idempotent
  /// no-op that publishes nothing.
  func applyBuvidSeed(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                      valueUnits: PiliCookieUTF16, nowMicroseconds: Int64) async throws
    -> PiliAccountShadowBuvidReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard current.schemaVersion == 3 else {
      throw PiliAccountShadowTransactionError.invalidBuvid
    }
    guard let index = current.records.firstIndex(where: {
      $0.record > 0 && $0.storageKeyUnits == recordKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.unknownRecordKey
    }
    let record = current.records[index]
    guard record.generation == expectedGeneration, record.isLogin else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    // Printable ASCII without the field separator and inside the intentional
    // API length ceiling: the value is interpolated into a single Set-Cookie
    // field, so CR/LF/';'/empty values and over-long values fail before any
    // field construction instead of surfacing a parser error.
    guard !valueUnits.units.isEmpty,
          valueUnits.units.allSatisfy({ $0 >= 0x21 && $0 < 0x7F && $0 != 0x3B }) else {
      throw PiliAccountShadowTransactionError.invalidBuvid
    }
    guard valueUnits.units.count <= Self.buvidMaximumValueUnits else {
      throw PiliAccountLiveMemoryShadowError.resourceLimit
    }
    if Self.hasBuvid3(record.jar) {
      return .init(transactionID: nil, seeded: false,
                   durableIdentity: record.durableIdentity,
                   nativeWritesAllowed: false, authoritySwitchAllowed: false)
    }
    let value = String(decoding: valueUnits.units, as: UTF16.self)
    let jar = try reducer.save(
      record.jar,
      fields: ["buvid3=\(value); Domain=.bilibili.com; Path=/"],
      representation: .separated,
      location: PiliOrderedCookieResponseLocation(host: "bilibili.com", path: "/"),
      nowMicroseconds: nowMicroseconds)
    let candidate = replaceJar(current, index: index, jar: jar)
    _ = try candidate.validated(limits: codec.limits)
    let publication = try await publishCandidate(candidate,
                                                 expectedTransactionID: snapshot.transactionID,
                                                 kind: .buvidSeed)
    return .init(transactionID: publication.transactionID, seeded: true,
                 durableIdentity: record.durableIdentity,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  /// Presence follows the Dart jar map key: the `buvid3` entry inside the
  /// `bilibili.com` domain bucket at path `/` (never the mutable Cookie.name).
  private static func hasBuvid3(_ jar: PiliOrderedCookieArchive) -> Bool {
    let domainKey = PiliCookieUTF16(units: Array("bilibili.com".utf16))
    let pathKey = PiliCookieUTF16(units: Array("/".utf16))
    let nameKey = PiliCookieUTF16(units: Array("buvid3".utf16))
    guard let bucket = jar.domainBuckets.first(where: { $0.keyUnits == domainKey }),
          let path = bucket.paths.first(where: { $0.keyUnits == pathKey }) else {
      return false
    }
    return path.cookies.contains(where: { $0.keyUnits == nameKey })
  }

  private static func renumbered(_ record: PiliAccountLiveMemoryRecord,
                                 as index: Int) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: index, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
  }

  private static func mintIdentity(excluding existing: Set<PiliCookieUTF16>) -> PiliCookieUTF16 {
    while true {
      let candidate = PiliCookieUTF16(units: Array(UUID().uuidString.lowercased().utf16))
      if !existing.contains(candidate) { return candidate }
    }
  }

  private func transaction(recordKeyUnits: PiliCookieUTF16, expectedGeneration: Int64,
                           kind: PiliAccountShadowUnresolvedWriteKind,
                           _ transform: (PiliAccountLiveMemoryShadow, Int) throws
                             -> PiliAccountLiveMemoryShadow) async throws
    -> PiliAccountShadowTransactionReceipt {
    try beginOperation()
    defer { operationInProgress = false }
    guard let snapshot = try await vault.loadShadowSnapshot() else {
      throw PiliAccountShadowTransactionError.shadowUnavailable
    }
    let current = snapshot.envelope
    guard let index = current.records.firstIndex(where: {
      $0.record > 0 && $0.storageKeyUnits == recordKeyUnits
    }) else {
      throw PiliAccountShadowTransactionError.unknownRecordKey
    }
    let record = current.records[index]
    guard record.generation == expectedGeneration, record.isLogin else {
      throw PiliAccountShadowTransactionError.staleGeneration
    }
    let candidate = try transform(current, index)
    // The complete candidate must still fit the shared cumulative ledger.
    _ = try candidate.validated(limits: codec.limits)
    // The wrapper gate cannot fence other callers of the shared vault. Publish
    // only if the exact pointer used for this transform is still current; the
    // vault owns comparison and publication under one operation fence.
    let publication = try await publishCandidate(candidate,
                                                 expectedTransactionID: snapshot.transactionID,
                                                 kind: kind)
    return .init(transactionID: publication.transactionID, record: record.record,
                 durableIdentity: record.durableIdentity,
                 nativeWritesAllowed: false, authoritySwitchAllowed: false)
  }

  private func slotIndex(_ purpose: PiliAccountPurpose) -> Int {
    // The source order is fixed: main, heartbeat, recommend, video.
    switch purpose {
    case .main: return 0
    case .heartbeat: return 1
    case .recommend: return 2
    case .video: return 3
    }
  }

  private static func replacingPurposes(
    _ record: PiliAccountLiveMemoryRecord, purposes: [PiliAccountPurpose]
  ) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: purposes,
      activated: record.activated, jar: record.jar, durableIdentity: record.durableIdentity)
  }

  private static func replacingIdentity(
    _ record: PiliAccountLiveMemoryRecord, identity: PiliCookieUTF16
  ) -> PiliAccountLiveMemoryRecord {
    PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: record.jar, durableIdentity: identity)
  }

  private func replaceJar(_ current: PiliAccountLiveMemoryShadow, index: Int,
                          jar: PiliOrderedCookieArchive) -> PiliAccountLiveMemoryShadow {
    let record = current.records[index]
    var records = current.records
    records[index] = PiliAccountLiveMemoryRecord(
      record: record.record, generation: record.generation, storageKeyUnits: record.storageKeyUnits,
      mid: record.mid, isLogin: record.isLogin, accessKeyUnits: record.accessKeyUnits,
      refreshTokenUnits: record.refreshTokenUnits, persistedPurposes: record.persistedPurposes,
      activated: record.activated, jar: jar, durableIdentity: record.durableIdentity)
    return replace(current, records: records)
  }

  private func replace(_ current: PiliAccountLiveMemoryShadow,
                       records: [PiliAccountLiveMemoryRecord]? = nil,
                       storedOrder: [PiliAccountLiveMemoryOrderEntry]? = nil,
                       ownerOrder: [PiliAccountLiveMemoryOrderEntry]? = nil,
                       selections: [Int]? = nil,
                       history: Int? = nil,
                       schemaVersion: Int? = nil,
                       generationHighWater: Int64? = nil) -> PiliAccountLiveMemoryShadow {
    let version = schemaVersion ?? current.schemaVersion
    let carried = generationHighWater ?? current.generationHighWater
    // Schema 3 must never lose the monotonic high-water: legacy envelopes that
    // omitted/nulled the field persist the pre-transform effective value on
    // every publication, so deleting the maximum or last login cannot lower
    // the water that later guards reused generations against. Schema 2 keeps
    // its strict nil shape.
    let resolvedHighWater: Int64? = version == 3
      ? max(carried ?? 0, current.effectiveGenerationHighWater)
      : nil
    return PiliAccountLiveMemoryShadow(
      schemaVersion: version,
      scope: current.scope, identityScope: current.identityScope,
      revision: current.revision, durableIdentityConfigured: current.durableIdentityConfigured,
      durabilityVerified: current.durabilityVerified,
      authoritySwitchAllowed: current.authoritySwitchAllowed,
      nativeWritesAllowed: current.nativeWritesAllowed,
      records: records ?? current.records,
      storedOrder: storedOrder ?? current.storedOrder,
      ownerOrder: ownerOrder ?? current.ownerOrder, selectionPurposes: current.selectionPurposes,
      selections: selections ?? current.selections, history: history ?? current.history,
      generationHighWater: resolvedHighWater)
  }

  private func beginOperation() throws {
    // Actor methods can reenter across awaits; fence the load/transform/publish
    // transaction until its durable publication has finished. Direct public
    // entry is a legacy primitive that fails closed while a queued turn holds
    // the writer role (executing, retrying or reserved) and while an unresolved
    // publication awaits its recorded read-back resolution. Queued attempts
    // pass because they execute inside `executingQueuedTurn`.
    guard !operationInProgress else {
      throw PiliAccountShadowTransactionError.operationInProgress
    }
    try requireResolvedPublication()
    guard !writerActive || executingQueuedTurn else {
      throw PiliAccountShadowTransactionError.operationInProgress
    }
    operationInProgress = true
  }
}
