import Foundation

private struct Failure: Error { let message: String }

private actor Provider: PiliHTTPRequestContextProviding {
  let context: PiliHTTPRequestContext
  var prepares = 0, finishes = 0, abandons = 0
  var cookies: PiliHTTPRequestResponseCookies?
  var finishError = false
  var abandonOutcome: PiliHTTPRequestContextOutcome = .abandoned
  var cancelPrepare = false
  var retryDenied = false
  var retries: [Int64] = []
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
  func prepareRetry(_ context: PiliHTTPRequestContext, attempt: Int64) async throws -> [String: String] {
    retries.append(attempt)
    if retryDenied { throw PiliHTTPRequestContextError.serviceFailure(code: "revoked") }
    return ["accept-encoding": "br,gzip", "cookie": "fixture=retry-\(attempt)"]
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
  func configure(finishError: Bool = false, abandon: PiliHTTPRequestContextOutcome = .abandoned, cancel: Bool = false,
                 retryDenied: Bool = false) {
    self.finishError = finishError; abandonOutcome = abandon; cancelPrepare = cancel
    self.retryDenied = retryDenied
  }
}

private actor Transfer: PiliHTTPTransferring {
  enum Mode: Sendable, Equatable { case success, headCancel, headError, noHead, delayedBody, duplicateHead, unsupportedFields }
  let mode: Mode
  let provider: Provider
  let refusals: Int
  var calls = 0
  var headFinishedBeforeBody = false
  var sent: [ContinuousClock.Instant] = []
  var sentCookies: [String?] = []
  init(_ mode: Mode, provider: Provider, refusals: Int = 0) {
    self.mode = mode; self.provider = provider; self.refusals = refusals
  }
  func transfer(_ request: URLRequest, onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void) async -> PiliHTTPTransferOutcome {
    calls += 1
    sent.append(.now)
    sentCookies.append(request.value(forHTTPHeaderField: "Cookie"))
    if calls <= refusals {
      return .init(head: nil, body: .failure(.client(.nativeTransport(kind: "connectionRefused"))),
                   failedDuringInitialConnection: true)
    }
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
                     proxy: PiliPreparedHTTPPolicy.Proxy? = nil, issues: [PiliPreparedHTTPPolicy.Issue] = [],
                     http2: Bool = false, followRedirects: Bool = false, maxRedirects: Int64 = 5,
                     send: Int64? = nil, transform: Int64? = nil) -> PiliPreparedHTTPPolicy {
    .init(version: 1, poolGeneration: 1, clientMode: .http11,
      pool: .init(http2Enabled: http2, idleTimeoutMicroseconds: 15_000_000,
        http11AcceptsBadCertificate: proxy != nil, http2AcceptsBadCertificate: http2 ? false : nil,
        proxy: proxy, autoUncompress: false, http2ALPN: http2 ? ["h2"] : []),
      retry: .init(installed: delay != nil, count: retryCount, delayMilliseconds: delay),
      connectTimeoutMicroseconds: connect, receiveIdleTimeoutMicroseconds: receive,
      sendTimeoutMicroseconds: send, transformTimeoutMicroseconds: transform,
      receiveDataWhenStatusError: true, persistentConnection: true, followRedirects: followRedirects,
      maxRedirects: maxRedirects, acceptEncoding: "br,gzip", responseType: "json",
      decoder: .manualCompressionUTF8, issues: issues)
  }
  static func rawHTTP11Preflight(_ evaluator: PiliHTTPPolicyCapability) throws {
    let precise = policy(connect: 10_000_001, receive: 7_000_003)
    try expect(evaluator.planRawHTTP11(precise) == .candidate(.init(
      poolGeneration: 1, connectMicroseconds: 10_000_001, receiveIdleMicroseconds: 7_000_003,
      poolIdleMicroseconds: 15_000_000, redirectLimit: nil)), "Raw candidate preserves microseconds and pool generation")
    try expect(evaluator.evaluate(precise, evidence: .rawCandidate) == .dart([.unverifiedTransport]),
               "An exact mapping still cannot authorize production traffic")
    for disabled: Int64? in [nil, 0] {
      try expect(evaluator.planRawHTTP11(policy(receive: disabled, delay: 37, send: 0, transform: 0))
        == .candidate(.init(poolGeneration: 1, connectMicroseconds: 10_000_000, receiveIdleMicroseconds: nil,
                           poolIdleMicroseconds: 15_000_000, redirectLimit: nil)), "Absent and zero idle timeout map to disabled")
    }
    for limit in [0, 5] {
      let redirects = policy(followRedirects: true, maxRedirects: Int64(limit))
      try expect(evaluator.planRawHTTP11(redirects) == .candidate(.init(poolGeneration: 1,
        connectMicroseconds: 10_000_000, receiveIdleMicroseconds: 10_000_000, poolIdleMicroseconds: 15_000_000,
        redirectLimit: limit)), "A configured redirect limit is distinct from disabled redirects")
      try expect(evaluator.evaluate(redirects, evidence: .rawCandidate) == .dart([.unverifiedTransport]),
                 "Same-origin mapping alone cannot authorize the runtime")
    }
    let rejected: [(PiliPreparedHTTPPolicy, [PiliHTTPPolicyRejection])] = [
      (policy(connect: nil), [.connectTimeout]),
      (policy(connect: 0), [.connectTimeout]),
      (policy(receive: -1), [.invalidDuration]),
      (policy(receive: Int64.max), [.durationOverflow]),
      (policy(retryCount: 2, delay: 500, followRedirects: true), [.retry]),
      (policy(delay: 37, followRedirects: true), [.retry]),
      (policy(followRedirects: true, maxRedirects: -1), [.redirect]),
      (policy(proxy: .init(host: "fixture", port: 8080)), [.proxy, .certificateTrust]),
      (policy(issues: [.decoderChanged]), [.undescribedPolicy]),
      (policy(http2: true), [.protocolSelection]),
      (policy(send: 1, transform: 1), [.sendTimeout, .transformTimeout])
    ]
    for (request, reasons) in rejected {
      try expect(evaluator.planRawHTTP11(request) == .unsupported(reasons), "Specific raw incompatibilities")
      try expect(evaluator.evaluate(request, evidence: .rawCandidate) == .dart([.unverifiedTransport] + reasons),
                 "Unsupported policy is declined before the raw transfer")
    }
  }
  static func execute(_ provider: Provider, _ transfer: Transfer,
                      evidence: PiliHTTPTransportEvidence = .syntheticComplete) async throws -> PiliPreparedHTTPRequestExecution {
    try await PiliPreparedHTTPRequestExecutor(provider: provider, transport: transfer, evidence: evidence)
      .execute(.searchTrending(limit: 10))
  }
  static func initialConnectionRetries() async throws {
    let configured = policy(retryCount: 2, delay: 25)
    let success = Provider(policy: configured), recovered = Transfer(.success, provider: success, refusals: 2)
    guard case .transferred(let outcome, let receipt, _, _) = try await execute(success, recovered) else {
      throw Failure(message: "Failed Swift attempts must never replay via Dart")
    }
    try expect(outcome.head?.statusCode == 403 && receipt.outcome == .finished, "Recovery finishes only the final head")
    let finalized = await success.counts(), retryAttempts = await success.retries
    try expect(finalized == [1, 1, 0] && retryAttempts == [1, 2], "One lease for both retries")
    try expect(await recovered.sentCookies == [nil, "fixture=retry-1", "fixture=retry-2"], "Refresh precedes each attempt")
    let sent = await recovered.sent
    try expect(sent.count == 3 && sent[0].duration(to: sent[1]) >= .milliseconds(25)
      && sent[1].duration(to: sent[2]) >= .milliseconds(50), "Retry wait multiplies by attempt")

    let exhausted = Provider(policy: configured), stillRefused = Transfer(.success, provider: exhausted, refusals: 3)
    guard case .transferred = try await execute(exhausted, stillRefused) else {
      throw Failure(message: "Retry exhaustion invoked a second transport")
    }
    let exhaustedCalls = await stillRefused.calls, exhaustedTerminals = await exhausted.counts()
    try expect(exhaustedCalls == 3 && exhaustedTerminals == [1, 0, 1], "Exhaustion abandons once")

    for mode in [Transfer.Mode.noHead, .headError, .headCancel] {
      let provider = Provider(policy: configured), transfer = Transfer(mode, provider: provider)
      _ = try await execute(provider, transfer)
      let calls = await transfer.calls, retries = await provider.retries
      try expect(calls == 1 && retries.isEmpty, "No resend after unclassified error, observed head or cancellation")
    }

    let denied = Provider(policy: configured), revoked = Transfer(.success, provider: denied, refusals: 1)
    await denied.configure(retryDenied: true)
    do { _ = try await execute(denied, revoked); throw Failure(message: "Revoked retry sent") }
    catch PiliHTTPRequestContextError.serviceFailure(code: "revoked") { checks += 1 }
    let deniedCalls = await revoked.calls, deniedTerminals = await denied.counts()
    try expect(deniedCalls == 1 && deniedTerminals == [1, 0, 1], "Revoked retry settles the original lease")

    let cancel = Provider(policy: policy(retryCount: 2, delay: 500)), waiting = Transfer(.success, provider: cancel, refusals: 1)
    let operation = Task { try await execute(cancel, waiting) }
    for _ in 0..<500 {
      if await waiting.calls == 1 { break }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    operation.cancel()
    do { _ = try await operation.value; throw Failure(message: "Cancelled retry sent") }
    catch is CancellationError { checks += 1 }
    let calls = await waiting.calls, retries = await cancel.retries, terminals = await cancel.counts()
    try expect(calls == 1 && retries.isEmpty && terminals == [1, 0, 1],
               "Cancellation during backoff stops before reauthorization")
  }
  static func main() async {
    do {
      let evaluator = PiliHTTPPolicyCapability()
      try expect(evaluator.evaluate(policy(), evidence: .syntheticComplete) == .native, "Only synthetic complete evidence supports fixture")
      guard case .dart(let reasons) = evaluator.evaluate(policy(), evidence: .foundationBaseline) else {
        throw Failure(message: "Unverified Foundation transport accepted")
      }
      try expect(reasons.contains(.unverifiedTransport) && reasons.contains(.requestSemantics), "Foundation cannot authorize runtime")
      try expect(Set(reasons).count == reasons.count, "Reasons deterministic and unique")
      try rawHTTP11Preflight(evaluator)
      try await initialConnectionRetries()
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
        guard case .transferred(let outcome, let receipt, let generation, let requestedURL) = try await execute(provider, transfer) else { throw Failure(message: "Sent request cannot fall back") }
        try expect(generation == 4, "Sent request retains the prepared account generation")
        try expect(requestedURL.path == "/x/v2/search/trending/ranking", "Original endpoint remains the decode scope")
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
