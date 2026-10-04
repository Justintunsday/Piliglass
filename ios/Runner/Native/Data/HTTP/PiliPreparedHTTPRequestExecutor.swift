import Foundation

enum PiliPreparedHTTPRequestExecution: Sendable {
  /// Returned only after a confirmed abandon and zero transport calls.
  case dartFallback([PiliHTTPPolicyRejection])
  /// A sent request never falls back, including missing head, body failure or
  /// cancelled transfer. The caller decides how to present that single result.
  case transferred(PiliHTTPTransferOutcome, PiliHTTPRequestContextReceipt)
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

  init(provider: any PiliHTTPRequestContextProviding,
       transport: any PiliHTTPTransferring, evidence: PiliHTTPTransportEvidence) {
    self.provider = provider; self.transport = transport; self.evidence = evidence
  }

  func execute(_ purpose: PiliHTTPRequestPurpose) async throws -> PiliPreparedHTTPRequestExecution {
    try Task.checkCancellation()
    let context = try await provider.prepare(purpose)
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
    var request = URLRequest(url: context.request.url)
    request.httpMethod = "GET"
    request.allHTTPHeaderFields = context.request.headers
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if Task.isCancelled {
      _ = try await provider.abandon(context)
      throw CancellationError()
    }
    let terminal = PiliHTTPHeadTerminal(context: context, provider: provider)
    let outcome = await transport.transfer(request, onHead: { terminal.observe($0) })
    // Finalization starts at response head, before a slow or infinite body can
    // exhaust the Dart lease TTL. It remains alive across caller cancellation.
    // No second finish/abandon is sent if its acknowledgement is lost.
    let receipt = try await terminal.complete(outcome)
    return .transferred(outcome, receipt)
  }
}

/// Lock guards the one terminal Task shared by a synchronous transport callback
/// and the async completion observer. There is no lock held over an await.
private final class PiliHTTPHeadTerminal: @unchecked Sendable {
  private let lock = NSLock()
  private let context: PiliHTTPRequestContext
  private let provider: any PiliHTTPRequestContextProviding
  private var operation: Task<PiliHTTPRequestContextReceipt, Error>?

  init(context: PiliHTTPRequestContext, provider: any PiliHTTPRequestContextProviding) {
    self.context = context; self.provider = provider
  }

  func observe(_ head: PiliHTTPResponseHead) {
    _ = claim(head)
  }

  func complete(_ outcome: PiliHTTPTransferOutcome) async throws -> PiliHTTPRequestContextReceipt {
    try await claim(outcome.head).value
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
