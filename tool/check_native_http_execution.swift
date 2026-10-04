import Foundation

private struct Failure: Error { let message: String }

private actor Provider: PiliHTTPRequestContextProviding {
  let context: PiliHTTPRequestContext
  var prepares = 0, finishes = 0, abandons = 0
  var cookies: PiliHTTPRequestResponseCookies?
  var finishError = false
  var abandonOutcome: PiliHTTPRequestContextOutcome = .abandoned
  var cancelPrepare = false
  init(policy: PiliPreparedHTTPPolicy, invalidURL: Bool = false) {
    context = PiliHTTPRequestContext(requestID: "request", leaseID: "lease",
      request: .init(url: URL(string: invalidURL ? "https://api.bilibili.com/x/other?limit=10"
        : "https://api.bilibili.com/x/v2/search/trending/ranking?limit=10")!,
        method: "GET", headers: ["accept-encoding": "br,gzip"]),
      revision: 3, generation: 4, limit: 10, policy: policy)
  }
  func prepare(_ purpose: PiliHTTPRequestPurpose) async throws -> PiliHTTPRequestContext {
    prepares += 1
    if cancelPrepare { throw CancellationError() }
    return context
  }
  func finish(_ context: PiliHTTPRequestContext, response: PiliHTTPRequestResponseCookies) async throws -> PiliHTTPRequestContextReceipt {
    finishes += 1; cookies = response
    if finishError { throw PiliHTTPRequestContextError.terminalTimeout }
    return .init(outcome: .finished, cookiesSaved: true, cookieCount: response.setCookieValues.count)
  }
  func abandon(_ context: PiliHTTPRequestContext) async throws -> PiliHTTPRequestContextReceipt {
    abandons += 1
    return .init(outcome: abandonOutcome, cookiesSaved: false, cookieCount: 0)
  }
  func counts() -> [Int] { [prepares, finishes, abandons] }
  func configure(finishError: Bool = false, abandon: PiliHTTPRequestContextOutcome = .abandoned, cancel: Bool = false) {
    self.finishError = finishError; abandonOutcome = abandon; cancelPrepare = cancel
  }
}

private actor Transfer: PiliHTTPTransferring {
  enum Mode: Sendable, Equatable { case success, headCancel, headError, noHead, delayedBody, duplicateHead, unsupportedFields }
  let mode: Mode
  let provider: Provider
  var calls = 0
  var headFinishedBeforeBody = false
  init(_ mode: Mode, provider: Provider) { self.mode = mode; self.provider = provider }
  func transfer(_ request: URLRequest, onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void) async -> PiliHTTPTransferOutcome {
    calls += 1
    if mode == .noHead { return .init(head: nil, body: .failure(.client(.transport(code: -1)))) }
    let head = PiliHTTPResponseHead(url: request.url!, statusCode: 403, headers: [:],
      cookieFields: mode == .unsupportedFields ? .unsupported : .separatedFields(["same=path; Path=/x", "same=root; Path=/"]))
    onHead(head)
    if mode == .duplicateHead { onHead(head) }
    if mode == .delayedBody {
      for _ in 0..<200 {
        if await provider.finishes == 1 { headFinishedBeforeBody = true; break }
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
    }
    let body: Result<Data, PiliHTTPTransferFailure>
    switch mode {
    case .headCancel: body = .failure(.cancelled)
    case .headError: body = .failure(.client(.transport(code: -1005)))
    default: body = .success(Data("body".utf8))
    }
    return .init(head: head, body: body)
  }
}

@main @MainActor
private struct ExecutionChecks {
  static var checks = 0
  static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }; checks += 1
  }
  static func policy(connect: Int64? = 10_000_000, receive: Int64? = 10_000_000,
                     retryCount: Int64 = 0, delay: Int64? = nil,
                     proxy: PiliPreparedHTTPPolicy.Proxy? = nil, issues: [PiliPreparedHTTPPolicy.Issue] = []) -> PiliPreparedHTTPPolicy {
    .init(version: 1, poolGeneration: 1, clientMode: .http11,
      pool: .init(http2Enabled: false, idleTimeoutMicroseconds: 15_000_000,
        http11AcceptsBadCertificate: proxy != nil, http2AcceptsBadCertificate: nil,
        proxy: proxy, autoUncompress: false, http2ALPN: []),
      retry: .init(installed: delay != nil, count: retryCount, delayMilliseconds: delay),
      connectTimeoutMicroseconds: connect, receiveIdleTimeoutMicroseconds: receive,
      sendTimeoutMicroseconds: nil, transformTimeoutMicroseconds: nil,
      receiveDataWhenStatusError: true, persistentConnection: true, followRedirects: false,
      maxRedirects: 5, acceptEncoding: "br,gzip", responseType: "json",
      decoder: .manualCompressionUTF8, issues: issues)
  }
  static func execute(_ provider: Provider, _ transfer: Transfer,
                      evidence: PiliHTTPTransportEvidence = .syntheticComplete) async throws -> PiliPreparedHTTPRequestExecution {
    try await PiliPreparedHTTPRequestExecutor(provider: provider, transport: transfer, evidence: evidence)
      .execute(.searchTrending(limit: 10))
  }
  static func main() async {
    do {
      let evaluator = PiliHTTPPolicyCapability()
      try expect(evaluator.evaluate(policy(), evidence: .syntheticComplete) == .native, "Only synthetic complete evidence supports fixture")
      for unsupported in [PiliHTTPTransportEvidence.foundationBaseline, .rawCandidate] {
        guard case .dart(let reasons) = evaluator.evaluate(policy(), evidence: unsupported) else {
          throw Failure(message: "Unverified transport accepted")
        }
        try expect(reasons.contains(.unverifiedTransport) && reasons.contains(.requestSemantics), "Real profiles cannot authorize runtime")
        try expect(Set(reasons).count == reasons.count, "Reasons deterministic and unique")
      }
      for invalid in [policy(connect: -1), policy(receive: Int64.max), policy(retryCount: -1, delay: 10),
                      policy(delay: -1), policy(delay: Int64.max),
                      policy(proxy: .init(host: "fixture", port: -1)), policy(issues: [.decoderChanged])] {
        guard case .dart = evaluator.evaluate(invalid, evidence: .syntheticComplete) else { throw Failure(message: "Invalid input accepted") }
        checks += 1
      }
      for duration: Int64? in [nil, 0, 1, 10_000_000] {
        try expect(evaluator.evaluate(policy(connect: duration, receive: duration), evidence: .syntheticComplete) == .native,
                   "Synthetic evidence explicitly includes nil/zero/positive semantics")
      }
      for delay: Int64? in [nil, 0, 1] {
        try expect(evaluator.evaluate(policy(delay: delay), evidence: .syntheticComplete) == .native, "Absent and installed-zero retry retain distinct inputs")
      }
      let fallbackProvider = Provider(policy: policy()), fallbackTransfer = Transfer(.success, provider: fallbackProvider)
      guard case .dartFallback = try await execute(fallbackProvider, fallbackTransfer, evidence: .foundationBaseline) else { throw Failure(message: "Fallback expected") }
      try expect(await fallbackTransfer.calls == 0, "Unsupported never sends")
      try expect(await fallbackProvider.counts() == [1, 0, 1], "Unsupported abandons once")
      let unknownProvider = Provider(policy: policy()), unknownTransfer = Transfer(.success, provider: unknownProvider)
      await unknownProvider.configure(abandon: .unknown)
      do { _ = try await execute(unknownProvider, unknownTransfer, evidence: .foundationBaseline); throw Failure(message: "Unknown ack allowed replay") }
      catch PiliPreparedHTTPRequestExecutionError.terminalNotConfirmed(.unknown) { checks += 1 }
      try expect(await unknownProvider.counts() == [1, 0, 1], "Unknown abandon cannot retransmit")
      for mode in [Transfer.Mode.success, .headCancel, .headError, .delayedBody, .duplicateHead] {
        let provider = Provider(policy: policy()), transfer = Transfer(mode, provider: provider)
        guard case .transferred(let outcome, let receipt) = try await execute(provider, transfer) else { throw Failure(message: "Sent request cannot fall back") }
        try expect(await provider.counts() == [1, 1, 0], "Head outcomes finish exactly once")
        try expect(outcome.head?.statusCode == 403 && receipt.outcome == .finished, "HTTP/API failure does not discard head")
        let cookies = await provider.cookies
        try expect(cookies?.cookieSource == .separatedFields && cookies?.setCookieValues == ["same=path; Path=/x", "same=root; Path=/"], "Raw field order/provenance reaches original owner")
        if mode == .delayedBody { try expect(await transfer.headFinishedBeforeBody, "Lease finished while body is still pending") }
      }
      let noHeadProvider = Provider(policy: policy()), noHead = Transfer(.noHead, provider: noHeadProvider)
      guard case .transferred = try await execute(noHeadProvider, noHead) else { throw Failure(message: "Missing head after send must not replay") }
      try expect(await noHeadProvider.counts() == [1, 0, 1], "No head abandons once but never falls back")
      let failed = Provider(policy: policy()), failedTransfer = Transfer(.headError, provider: failed)
      await failed.configure(finishError: true)
      do { _ = try await execute(failed, failedTransfer); throw Failure(message: "Unknown finish ack accepted") }
      catch PiliHTTPRequestContextError.terminalTimeout { checks += 1 }
      try expect(await failed.counts() == [1, 1, 0], "Unknown finish never starts another terminal")
      let cancel = Provider(policy: policy()), cancelledTransfer = Transfer(.success, provider: cancel)
      await cancel.configure(cancel: true)
      do { _ = try await execute(cancel, cancelledTransfer); throw Failure(message: "Prepare cancel ignored") }
      catch is CancellationError { checks += 1 }
      try expect(await cancelledTransfer.calls == 0, "Prepare cancellation zero sends")
      let invalid = Provider(policy: policy(), invalidURL: true), invalidTransfer = Transfer(.success, provider: invalid)
      do { _ = try await execute(invalid, invalidTransfer); throw Failure(message: "Arbitrary URL authorized") }
      catch PiliPreparedHTTPRequestExecutionError.invalidDescriptor { checks += 1 }
      try expect(await invalid.counts() == [1, 0, 1], "Endpoint preflight fails before send")
      print("\(checks) native HTTP execution checks passed")
    } catch { print("FAIL native HTTP execution: \(error)"); exit(1) }
  }
}
