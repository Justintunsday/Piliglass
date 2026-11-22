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

/// The endpoint descriptor and authority come from the prepared lease. This
/// executor grants no arbitrary URL/POST permissions and is not wired to Views.
struct PiliPreparedHTTPRequestExecutor: Sendable {
  private let provider: any PiliHTTPRequestContextProviding
  private let transport: any PiliHTTPTransferring
  private let evidence: PiliHTTPTransportEvidence
  private let validateResponseBody: (@Sendable (PiliHTTPResponse) throws -> Void)?

  init(provider: any PiliHTTPRequestContextProviding,
       transport: any PiliHTTPTransferring, evidence: PiliHTTPTransportEvidence,
       validateResponseBody: (@Sendable (PiliHTTPResponse) throws -> Void)? = nil) {
    self.provider = provider; self.transport = transport; self.evidence = evidence
    self.validateResponseBody = validateResponseBody
  }

  func execute(_ purpose: PiliHTTPRequestPurpose) async throws -> PiliPreparedHTTPRequestExecution {
    try Task.checkCancellation()
    var context = try await provider.prepare(purpose)
    if Task.isCancelled {
      _ = try await provider.abandon(context)
      throw CancellationError()
    }
    let decision = PiliHTTPPolicyCapability().evaluate(context.policy, evidence: evidence)
    if case .dart(let reasons) = decision {
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
    while true {
      if Task.isCancelled {
        _ = try await provider.abandon(context)
        throw CancellationError()
      }
      let limit = context.remainingRedirects.flatMap { Int(exactly: $0) }
      var request = URLRequest(url: context.request.url)
      request.httpMethod = "GET"
      request.allHTTPHeaderFields = context.request.headers
      request.httpShouldHandleCookies = false
      request.cachePolicy = .reloadIgnoringLocalCacheData
      let terminal = PiliHTTPHeadTerminal(context: context, provider: provider)
      var outcome = await transport.transfer(request, redirectLimit: limit, onHead: { terminal.observe($0) })
      if let retry = context.policy.retry, retry.installed, let delay = retry.delayMilliseconds, delay >= 0 {
        while attempt < retry.count, outcome.failedDuringInitialConnection, outcome.head == nil,
              !terminal.hasObservedHead, case .failure(.client(_)) = outcome.body {
          attempt += 1
          let (milliseconds, delayOverflow) = delay.multipliedReportingOverflow(by: attempt)
          let (nanoseconds, unitOverflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
          guard !delayOverflow, !unitOverflow else { break }
          do {
            try await Task.sleep(nanoseconds: UInt64(nanoseconds))
            let headers = try await provider.prepareRetry(context, attempt: attempt)
            try Task.checkCancellation()
            request.allHTTPHeaderFields = headers
          } catch {
            _ = try await terminal.complete(nil)
            throw error
          }
          outcome = await transport.transfer(request, redirectLimit: limit, onHead: { terminal.observe($0) })
        }
      }

      var finalHead = outcome.head
      if let head = finalHead, terminal.defers(head) {
        finalHead = nil
        if case .success(let body) = outcome.body {
          do {
            try Task.checkCancellation()
            guard let validateResponseBody else { throw PiliHTTPClientError.invalidResponse }
            try validateResponseBody(.init(url: head.url, statusCode: head.statusCode, headers: head.headers, body: body))
            if terminal.mayReissue(head) {
              context = try await provider.prepareRedirect(context, response: head)
              continue
            }
            finalHead = head
          } catch {
            _ = try await terminal.complete(nil)
            throw error
          }
        }
      }
      let receipt = try await terminal.complete(finalHead)
      return .transferred(outcome, receipt, generation: context.generation, requestedURL: endpoint)
    }
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

  var hasObservedHead: Bool { lock.withLock { observed } }

  func mayReissue(_ head: PiliHTTPResponseHead) -> Bool {
    context.mayReissueRedirect && (300..<400).contains(head.statusCode) && head.locationValues?.isEmpty == false
  }

  func defers(_ head: PiliHTTPResponseHead) -> Bool {
    // An interceptor only sees a response after Dio has transformed its body.
    // A reissued request's final result also goes back through Dio's error chain.
    context.redirectIndex > 0 || mayReissue(head)
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
