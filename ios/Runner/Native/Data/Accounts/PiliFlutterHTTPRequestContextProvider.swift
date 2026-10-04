import Foundation

/// Temporary account adapter. No Native HTTP client or feature is wired here.
@MainActor
final class PiliFlutterHTTPRequestContextProvider: PiliHTTPRequestContextProviding {
  private let transport: any PiliBridgeMethodTransport
  private let invoker: any PiliBridgeMethodInvoking
  private let maxActiveContexts: Int
  private let terminalTimeoutNanoseconds: UInt64
  private var entries: [String: PiliHTTPRequestContextEntry] = [:]
  private var disposed = false

  init(
    transport: any PiliBridgeMethodTransport,
    maxActiveContexts: Int = 32,
    terminalTimeoutNanoseconds: UInt64 = 5_000_000_000
  ) {
    precondition(maxActiveContexts > 0 && terminalTimeoutNanoseconds > 0)
    self.transport = transport
    invoker = PiliBridgeMethodInvoker(transport: transport)
    self.maxActiveContexts = maxActiveContexts
    self.terminalTimeoutNanoseconds = terminalTimeoutNanoseconds
  }

  var activeContextCount: Int { entries.count }

  func prepare(_ purpose: PiliHTTPRequestPurpose) async throws -> PiliHTTPRequestContext {
    try Task.checkCancellation()
    guard !disposed else { throw PiliHTTPRequestContextError.disposed }
    guard entries.count < maxActiveContexts else { throw PiliHTTPRequestContextError.capacity }
    let requestID = UUID().uuidString.lowercased()
    let arguments = try PiliHTTPRequestContextBridgeCodec.prepareArguments(requestID: requestID, purpose: purpose)
    let entry = PiliHTTPRequestContextEntry(requestID: requestID, purpose: purpose,
      finalizer: PiliBridgeLeaseFinalizer(transport: transport, requestID: requestID,
                                         timeoutNanoseconds: terminalTimeoutNanoseconds))
    entries[requestID] = entry
    let invoker = self.invoker
    // A separate operation can be explicitly cancelled by caller or dispose.
    // It captures request values and the invoker, never the provider.
    let operation = Task { @MainActor in
      try await invoker.invoke("prepareNativeHTTPRequest", arguments: arguments)
    }
    entry.preparation = operation
    do {
      let raw = try await withTaskCancellationHandler {
        try await operation.value
      } onCancel: {
        operation.cancel()
      }
      try Task.checkCancellation()
      guard !disposed, entries[requestID] === entry, !entry.ending else {
        throw PiliHTTPRequestContextError.disposed
      }
      let context = try PiliHTTPRequestContextBridgeCodec.decodePrepared(raw, requestID: requestID, purpose: purpose)
      try Task.checkCancellation()
      entry.preparation = nil
      entry.leaseID = context.leaseID
      return context
    } catch {
      entry.preparation = nil
      // Includes invalid codec and cancellation that discarded the lease ID.
      // A late prepare reply never starts a second token-based cleanup.
      beginAbandon(entry)
      if disposed { throw PiliHTTPRequestContextError.disposed }
      throw Self.error(error)
    }
  }

  func finish(
    _ context: PiliHTTPRequestContext,
    response: PiliHTTPRequestResponseCookies
  ) async throws -> PiliHTTPRequestContextReceipt {
    if disposed { return Self.receipt(.closed) }
    guard let entry = try matchingEntry(context) else { return Self.receipt(.consumed) }
    if entry.ending { return Self.receipt(.consumed) }
    let arguments: [String: PiliBridgeValue]
    do {
      arguments = try PiliHTTPRequestContextBridgeCodec.finishArguments(context: context, response: response)
    } catch {
      // Failed local preflight sends abandon instead of an invalid finish.
      beginAbandon(entry)
      throw Self.error(error)
    }
    entry.ending = true
    guard let terminal = entry.finalizer.start("finishNativeHTTPRequest", arguments: arguments) else {
      return Self.receipt(.consumed)
    }
    defer { remove(entry) }
    do {
      // Deliberately do not propagate caller cancellation to this side effect.
      return try PiliHTTPRequestContextBridgeCodec.decodeReceipt(try await terminal.value)
    } catch {
      // Unknown ack or a server preclaim rejection cannot prove zero mutation.
      // Do not send another terminal call; Dart TTL is the release fallback.
      throw Self.error(error)
    }
  }

  func abandon(_ context: PiliHTTPRequestContext) async throws -> PiliHTTPRequestContextReceipt {
    if disposed { return Self.receipt(.closed) }
    guard let entry = try matchingEntry(context) else { return Self.receipt(.consumed) }
    if entry.ending { return Self.receipt(.consumed) }
    entry.ending = true
    guard let terminal = entry.finalizer.start("abandonNativeHTTPRequest", arguments: abandonArguments(entry)) else {
      return Self.receipt(.consumed)
    }
    defer { remove(entry) }
    do { return try PiliHTTPRequestContextBridgeCodec.decodeReceipt(try await terminal.value) }
    catch { throw Self.error(error) }
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    let pending = Array(entries.values)
    entries.removeAll()
    for entry in pending {
      entry.preparation?.cancel()
      entry.preparation = nil
      beginAbandon(entry)
    }
  }

  private func matchingEntry(_ context: PiliHTTPRequestContext) throws -> PiliHTTPRequestContextEntry? {
    guard let key = PiliHTTPRequestContextBridgeCodec.canonicalID(context.requestID),
          let token = PiliHTTPRequestContextBridgeCodec.canonicalID(context.leaseID) else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    guard let entry = entries[key] else { return nil }
    guard entry.purpose.limit == context.limit,
          entry.leaseID.flatMap(PiliHTTPRequestContextBridgeCodec.canonicalID) == token else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    return entry
  }

  private func beginAbandon(_ entry: PiliHTTPRequestContextEntry) {
    guard !entry.ending else { return }
    entry.ending = true
    guard let terminal = entry.finalizer.start("abandonNativeHTTPRequest", arguments: abandonArguments(entry)) else {
      remove(entry)
      return
    }
    // The observation task does not keep the provider or UI owner alive.
    Task { @MainActor [weak self] in
      _ = await terminal.result
      self?.remove(entry)
    }
  }

  private func abandonArguments(_ entry: PiliHTTPRequestContextEntry) -> [String: PiliBridgeValue] {
    var arguments: [String: PiliBridgeValue] = ["requestID": .string(entry.requestID)]
    if let leaseID = entry.leaseID { arguments["leaseID"] = .string(leaseID) }
    return arguments
  }

  private func remove(_ entry: PiliHTTPRequestContextEntry) {
    if entries[entry.requestID] === entry { entries.removeValue(forKey: entry.requestID) }
  }

  private static func receipt(_ outcome: PiliHTTPRequestContextOutcome) -> PiliHTTPRequestContextReceipt {
    PiliHTTPRequestContextReceipt(outcome: outcome, cookiesSaved: false, cookieCount: 0)
  }

  private static func error(_ error: Error) -> Error {
    if error is CancellationError { return CancellationError() }
    if let error = error as? PiliHTTPRequestContextError { return error }
    if error is PiliBridgeLeaseFinalizationError { return PiliHTTPRequestContextError.terminalTimeout }
    switch error as? PiliBridgeInvocationError {
    case .unavailable: return PiliHTTPRequestContextError.bridgeFailure(code: "unavailable")
    case .invalidValue: return PiliHTTPRequestContextError.invalidResponse
    case .platform(let code, _): return PiliHTTPRequestContextError.bridgeFailure(code: code)
    case nil: return PiliHTTPRequestContextError.bridgeFailure(code: "unknown")
    }
  }
}

/// Capacity covers pending, prepared and ending entries. Never-finished contexts
/// consume a bounded slot until explicitly abandoned/disposed; Dart TTL does not
/// purge this Swift registry. No request snapshot is retained here.
@MainActor
private final class PiliHTTPRequestContextEntry {
  let requestID: String
  let purpose: PiliHTTPRequestPurpose
  let finalizer: PiliBridgeLeaseFinalizer
  var leaseID: String?
  var preparation: Task<PiliBridgeValue, Error>?
  var ending = false

  init(requestID: String, purpose: PiliHTTPRequestPurpose, finalizer: PiliBridgeLeaseFinalizer) {
    self.requestID = requestID
    self.purpose = purpose
    self.finalizer = finalizer
  }
}
