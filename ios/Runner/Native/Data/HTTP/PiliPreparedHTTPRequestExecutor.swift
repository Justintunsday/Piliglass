import Foundation

enum PiliPreparedHTTPRequestExecution: Sendable {
  /// Returned only after a confirmed abandon and zero transport calls.
  case dartFallback([PiliHTTPPolicyRejection])
  /// A sent request never falls back, including missing head, body failure or
  /// cancelled transfer. The caller decides how to present that single result.
  case transferred(PiliHTTPTransferOutcome, PiliHTTPRequestContextReceipt, generation: Int64, requestedURL: URL)
}

enum PiliPreparedHTTPRequestExecutionError: Error, Sendable, Equatable {
  case terminalNotConfirmed(PiliHTTPRequestContextOutcome)
  case invalidDescriptor
}

enum PiliPreparedHTTPTransportSelection: Sendable {
  case native(any PiliHTTPTransferring)
  case dart([PiliHTTPPolicyRejection])
}

/// A complete body that the response transformer could not decode.
/// Local resource limits and cancellation are deliberately separate errors.
struct PiliHTTPResponseDecodingFailure: Error {
  let underlying: any Error
}

/// The endpoint descriptor and authority come from the prepared lease. This
/// executor grants no arbitrary URL or method permissions.
struct PiliPreparedHTTPRequestExecutor: Sendable {
  typealias SelectTransport = @Sendable (PiliPreparedHTTPPolicy) async -> PiliPreparedHTTPTransportSelection

  private let provider: any PiliHTTPRequestContextProviding
  private let selectTransport: SelectTransport
  private let validateResponseBody: (@Sendable (PiliHTTPResponse) throws -> Void)?

  init(provider: any PiliHTTPRequestContextProviding,
       transport: any PiliHTTPTransferring, evidence: PiliHTTPTransportEvidence,
       validateResponseBody: (@Sendable (PiliHTTPResponse) throws -> Void)? = nil) {
    self.init(provider: provider, selectTransport: { policy in
      switch PiliHTTPPolicyCapability().evaluate(policy, evidence: evidence) {
      case .native: return .native(transport)
      case .dart(let reasons): return .dart(reasons)
      }
    }, validateResponseBody: validateResponseBody)
  }

  init(provider: any PiliHTTPRequestContextProviding, selectTransport: @escaping SelectTransport,
       validateResponseBody: (@Sendable (PiliHTTPResponse) throws -> Void)? = nil) {
    self.provider = provider
    self.selectTransport = selectTransport
    self.validateResponseBody = validateResponseBody
  }

  func execute(_ purpose: PiliHTTPRequestPurpose) async throws -> PiliPreparedHTTPRequestExecution {
    try Task.checkCancellation()
    var context = try await provider.prepare(purpose)
    if Task.isCancelled {
      _ = try await provider.abandon(context)
      throw CancellationError()
    }
    let transport: any PiliHTTPTransferring
    switch await selectTransport(context.policy) {
    case .native(let selected):
      transport = selected
    case .dart(let reasons):
      let receipt = try await provider.abandon(context)
      guard receipt.outcome == .abandoned else {
        throw PiliPreparedHTTPRequestExecutionError.terminalNotConfirmed(receipt.outcome)
      }
      try Task.checkCancellation()
      return .dartFallback(reasons)
    }
    guard context.request.method == "GET", context.request.url.scheme == "https",
          context.request.url.host == "api.bilibili.com",
          context.request.url.path == "/x/v2/search/trending/ranking",
          context.limit == purpose.limit, (1...30).contains(context.limit),
          let components = URLComponents(url: context.request.url, resolvingAgainstBaseURL: false),
          components.user == nil, components.password == nil, components.fragment == nil,
          components.port == nil || components.port == 443,
          components.queryItems == [URLQueryItem(name: "limit", value: String(context.limit))] else {
      _ = try await provider.abandon(context)
      throw PiliPreparedHTTPRequestExecutionError.invalidDescriptor
    }
    let endpoint = context.request.url
    var attempt: Int64 = 0
    var headers = context.request.headers
    while true {
      if Task.isCancelled {
        _ = try await provider.abandon(context)
        throw CancellationError()
      }
      let limit = context.remainingRedirects.flatMap { Int(exactly: $0) }
      var request = URLRequest(url: context.request.url)
      request.httpMethod = "GET"
      request.allHTTPHeaderFields = headers
      request.httpShouldHandleCookies = false
      request.cachePolicy = .reloadIgnoringLocalCacheData
      let terminal = PiliHTTPHeadTerminal(context: context, provider: provider)
      let outcome = await transport.transfer(request, redirectLimit: limit, onHead: { terminal.observe($0) })
      let validatedHead = Result { try responseHead(outcome, terminal: terminal) }
      let canRetry: Bool
      switch validatedHead {
      case .success:
        canRetry = terminal.canRetry(outcome)
      case .failure(let error):
        canRetry = error is PiliHTTPResponseDecodingFailure && terminal.canRetryDecoding(outcome.head)
      }

      if let retry = context.policy.retry, retry.installed, attempt < retry.count,
         let delay = retry.delayMilliseconds, delay >= 0, canRetry {
        attempt += 1
        let (milliseconds, delayOverflow) = delay.multipliedReportingOverflow(by: attempt)
        let (nanoseconds, unitOverflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        if !delayOverflow, !unitOverflow {
          do {
            try await Task.sleep(nanoseconds: UInt64(nanoseconds))
            headers = try await provider.prepareRetry(context, attempt: attempt)
            continue
          } catch {
            _ = try await terminal.complete(nil)
            throw error
          }
        }
      }

      let finalHead: PiliHTTPResponseHead?
      do {
        finalHead = try validatedHead.get()
        if let head = finalHead, terminal.mayReissue(head) {
          context = try await provider.prepareRedirect(context, response: head)
          headers = context.request.headers
          continue
        }
      } catch {
        _ = try await terminal.complete(nil)
        throw (error as? PiliHTTPResponseDecodingFailure)?.underlying ?? error
      }
      let receipt = try await terminal.complete(finalHead)
      return .transferred(outcome, receipt, generation: context.generation, requestedURL: endpoint)
    }
  }

  private func responseHead(
    _ outcome: PiliHTTPTransferOutcome,
    terminal: PiliHTTPHeadTerminal
  ) throws -> PiliHTTPResponseHead? {
    guard let head = outcome.head, terminal.defers(head) else { return outcome.head }
    guard case .success(let body) = outcome.body else { return nil }
    try Task.checkCancellation()
    guard let validateResponseBody else { throw PiliHTTPClientError.invalidResponse }
    try validateResponseBody(.init(url: head.url, statusCode: head.statusCode, headers: head.headers, body: body))
    try Task.checkCancellation()
    return head
  }
}

/// Lock guards the one terminal Task shared by a synchronous transport callback
/// and the async completion observer. There is no lock held over an await.
private final class PiliHTTPHeadTerminal: @unchecked Sendable {
  private let lock = NSLock()
  private let context: PiliHTTPRequestContext
  private let provider: any PiliHTTPRequestContextProviding
  private var observed = false
  private var operation: Task<PiliHTTPRequestContextReceipt, Error>?

  init(context: PiliHTTPRequestContext, provider: any PiliHTTPRequestContextProviding) {
    self.context = context; self.provider = provider
  }

  func observe(_ head: PiliHTTPResponseHead) {
    lock.withLock { observed = true }
    if !defers(head) { _ = claim(head) }
  }

  func canRetry(_ outcome: PiliHTTPTransferOutcome) -> Bool {
    guard case .failure(.client(_)) = outcome.body else { return false }
    return lock.withLock {
      guard operation == nil else { return false }
      switch outcome.retryEvidence {
      case .beforeResponseHead?: return outcome.head == nil && !observed
      case .incompleteResponseBody?: return outcome.head?.requiresCompleteBodyForWriteBack ?? !observed
      case nil: return false
      }
    }
  }

  func canRetryDecoding(_ head: PiliHTTPResponseHead?) -> Bool {
    guard head?.requiresCompleteBodyForWriteBack == true else { return false }
    return lock.withLock { operation == nil }
  }

  func mayReissue(_ head: PiliHTTPResponseHead) -> Bool {
    context.mayReissueRedirect && (300..<400).contains(head.statusCode) && head.locationValues?.isEmpty == false
  }

  func defers(_ head: PiliHTTPResponseHead) -> Bool {
    // An interceptor only sees a response after Dio has transformed its body.
    // A reissued request's final result also goes back through Dio's error chain.
    head.requiresCompleteBodyForWriteBack || context.redirectIndex > 0 || mayReissue(head)
  }

  func complete(_ head: PiliHTTPResponseHead?) async throws -> PiliHTTPRequestContextReceipt {
    try await claim(head).value
  }

  private func claim(_ head: PiliHTTPResponseHead?) -> Task<PiliHTTPRequestContextReceipt, Error> {
    lock.lock()
    defer { lock.unlock() }
    if let operation { return operation }
    let context = self.context, provider = self.provider
    let operation = Task {
      if let head {
        return try await PiliHTTPRequestHeaderFinalizer(provider: provider).finalize(context, head: head)
      }
      return try await provider.abandon(context)
    }
    self.operation = operation
    return operation
  }
}
