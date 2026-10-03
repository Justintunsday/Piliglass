import Foundation

private struct CheckFailure: Error { let message: String }

// URLProtocol callbacks use Foundation's threads. All mutable fixture state is
// private and accessed under this lock; unchecked conformance is test-only.
private final class HTTPFixtureState: @unchecked Sendable {
  enum Reply: Sendable {
    case response(URLResponse, Data)
    case error(URLError.Code)
    case hold
  }
  private let lock = NSLock()
  private var reply: Reply = .hold
  private var requests: [URLRequest] = []
  private var stops = 0
  func configure(_ reply: Reply) {
    lock.lock(); defer { lock.unlock() }
    self.reply = reply; requests = []; stops = 0
  }
  func start(_ request: URLRequest) -> Reply {
    lock.lock(); defer { lock.unlock() }
    requests.append(request)
    return reply
  }
  func stop() {
    lock.lock(); defer { lock.unlock() }
    stops += 1
  }
  func snapshot() -> (requests: [URLRequest], stops: Int) {
    lock.lock(); defer { lock.unlock() }
    return (requests, stops)
  }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
  static let state = HTTPFixtureState()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    switch Self.state.start(request) {
    case let .response(response, data):
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    case let .error(code): client?.urlProtocol(self, didFailWithError: URLError(code))
    case .hold: break
    }
  }
  override func stopLoading() { Self.state.stop() }
}

@main
@MainActor
private struct NativeHTTPChecks {
  static var checks = 0
  static let endpoint = URL(string: "https://api.bilibili.com/x/v2/search/trending/ranking?limit=10")!

  static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
    checks += 1
  }

  static func expectError<E: Error & Equatable>(
    _ expected: E, _ message: String, operation: () async throws -> Void
  ) async throws {
    do { try await operation() }
    catch let error as E { try expect(error == expected, message); return }
    catch { throw CheckFailure(message: "Unexpected error: \(message): \(error)") }
    throw CheckFailure(message: "Missing error: " + message)
  }

  static func expectCancellation(_ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch is CancellationError { checks += 1; return }
    throw CheckFailure(message: "Cancellation was not preserved")
  }

  static func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CheckFailure(message: "Fixture did not receive URLSession event")
  }

  static func response(_ json: String, status: Int = 200, url: URL? = nil) -> PiliHTTPResponse {
    PiliHTTPResponse(url: url ?? endpoint, statusCode: status,
                     headers: ["Content-Type": "application/json"], body: Data(json.utf8))
  }

  static func rawReply(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPFixtureState.Reply {
    .response(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1",
                              headerFields: headers)!, Data(json.utf8))
  }

  static func requestChecks() throws {
    let request = try PiliNativeSearchTrendingService.makeRequest(headers: [
      "Cookie": "same=path; same=root", "Referer": "https://www.bilibili.com/", "User-Agent": "fixture-agent"
    ])
    try expect(request.url == endpoint, "Endpoint and explicit native limit")
    try expect(request.httpMethod == "GET" && request.httpBody == nil, "Read-only GET")
    try expect(request.value(forHTTPHeaderField: "Cookie") == "same=path; same=root", "Duplicate cookie names/order retained")
    try expect(request.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/", "Context header retained")
    try expect(request.value(forHTTPHeaderField: "User-Agent") == "fixture-agent", "Context user agent retained")
    try expect(!request.httpShouldHandleCookies && request.timeoutInterval == 10, "Explicit cookie handling and timeout")
    let legacyDefault = try PiliNativeSearchTrendingService.makeRequest(headers: [:], limit: 30)
    try expect(legacyDefault.url?.query == "limit=30", "Legacy helper default supported")
    for limit in [-1, 0, 31, Int.max] {
      do { _ = try PiliNativeSearchTrendingService.makeRequest(headers: [:], limit: limit) }
      catch PiliHTTPClientError.invalidRequest { checks += 1; continue }
      throw CheckFailure(message: "Invalid limit accepted")
    }
    for (index, headers) in [
      ["Cookie": "value\r\nInjected: true"], ["Cookie": "value\rInjected: true"],
      ["Cookie": "value\nInjected: true"], ["Bad Header": "value"], ["": "value"],
      ["Cookie": "one", "cookie": "two"], ["Host": "other.example"], ["Content-Length": "1"]
    ].enumerated() {
      do { _ = try PiliNativeSearchTrendingService.makeRequest(headers: headers) }
      catch PiliHTTPClientError.invalidRequest { checks += 1; continue }
      throw CheckFailure(message: "Invalid header case \(index) accepted")
    }
  }

  static func decoderChecks() async throws {
    let mapped = try PiliSearchTrendingDecoder.decode(response(#"{"code":0,"data":{"list":[{"keyword":"first","show_name":"display","icon":" //example.com/a ","show_live_icon":true,"recommend_reason":"a·b·c"},{"keyword":"","icon":null},{"keyword":"  "},{"keyword":"null","icon":"http://example.com/b"},{"keyword":"last","icon":"null","recommend_reason":null}],"top_list":"ignored"}}"#))
    try expect(mapped.map(\.keyword) == ["first", "  ", "null", "last"], "Only empty keywords discarded; order retained")
    try expect(mapped[0].reason == "a b·c", "Only first middle dot replaced")
    try expect(mapped[0].icon == "https://example.com/a" && mapped[2].icon == "https://example.com/b", "Legacy icon normalization")
    try expect(mapped[1].reason.isEmpty && mapped[3].icon == nil, "Nullable reason/icon defaults")
    try expect(try PiliSearchTrendingDecoder.decode(response(#"{"code":0,"data":{}}"#)).isEmpty, "Missing list is empty")
    try expect(try PiliSearchTrendingDecoder.decode(response(#"{"code":0,"data":{"list":null}}"#)).isEmpty, "Null list is empty")
    try expect(try PiliSearchTrendingDecoder.decode(response(#"{"code":0.0,"data":{"list":[]}}"#)).isEmpty, "Numeric zero envelope")
    let ignoredMessage = try PiliSearchTrendingDecoder.decode(response(#"{"code":0,"message":123,"data":{"list":[{"keyword":"ok"}]}}"#))
    try expect(ignoredMessage.first?.keyword == "ok", "Success ignores unused message type like Dart")
    let items = Array(repeating: #"{"keyword":"duplicate","icon":"relative/path"}"#, count: 12).joined(separator: ",")
    let many = try PiliSearchTrendingDecoder.decode(response("{\"code\":0,\"data\":{\"list\":[" + items + "]}}"))
    try expect(many.count == 12 && many[0].icon == "relative/path", "No truncation/dedup or invented URL normalization")
    for json in ["", "[]", "null", #"{"data":{}}"#, #"{"code":true,"data":{}}"#,
                 #"{"code":0,"data":null}"#, #"{"code":0,"data":[]}"#,
                 #"{"code":0,"data":{"list":{}}}"#, #"{"code":0,"data":{"list":[null]}}"#,
                 #"{"code":0,"data":{"list":[{}]}}"#, #"{"code":0,"data":{"list":[{"keyword":2}]}}"#,
                 #"{"code":0,"data":{"list":[{"keyword":"a","icon":3}]}}"#,
                 #"{"code":0,"data":{"list":[{"keyword":"a","show_name":false}]}}"#,
                 #"{"code":0,"data":{"list":[{"keyword":"a","show_live_icon":1}]}}"#,
                 #"{"code":0,"data":{"list":[{"keyword":"a","recommend_reason":{}}]}}"#] {
      try await expectError(PiliSearchTrendingError.invalidPayload, "Malformed envelope/row fails whole partition") {
        _ = try PiliSearchTrendingDecoder.decode(response(json))
      }
    }
    try await expectError(PiliSearchTrendingError.api(code: -101, message: "expired"), "API error before success-payload validation") {
      _ = try PiliSearchTrendingDecoder.decode(response(#"{"code":-101,"message":"expired","data":"ignored"}"#))
    }
    try await expectError(PiliSearchTrendingError.api(code: -400, message: nil), "API error without message") {
      _ = try PiliSearchTrendingDecoder.decode(response(#"{"code":-400}"#))
    }
    for status in [302, 403, 429, 500] {
      try await expectError(PiliSearchTrendingError.httpStatus(status), "HTTP error before JSON parsing") {
        _ = try PiliSearchTrendingDecoder.decode(response("html", status: status))
      }
    }
    try await expectError(PiliHTTPClientError.invalidResponse, "Unexpected response origin rejected") {
      _ = try PiliSearchTrendingDecoder.decode(response(#"{"code":0,"data":{}}"#, url: URL(string: "https://other.example/")!))
    }
  }

  static func transportChecks() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureURLProtocol.self]
    configuration.httpCookieStorage = .shared
    configuration.httpShouldSetCookies = true
    let client = PiliURLSessionHTTPClient(configuration: configuration)
    try expect(configuration.httpCookieStorage === HTTPCookieStorage.shared && configuration.httpShouldSetCookies,
               "Client did not mutate caller configuration")
    let request = try PiliNativeSearchTrendingService.makeRequest(headers: ["Cookie": "same=path; same=root"])
    let sharedCookie = HTTPCookie(properties: [.domain: "api.bilibili.com", .path: "/", .name: "fixture_shared", .value: "must_not_leak", .secure: "TRUE"])!
    HTTPCookieStorage.shared.setCookie(sharedCookie)
    defer { HTTPCookieStorage.shared.deleteCookie(sharedCookie) }
    let fixture = FixtureURLProtocol.state
    fixture.configure(rawReply("error-body", status: 403, headers: ["Set-Cookie": "fixture_response=one; Path=/; Secure", "X-Trace": "trace-value"]))
    let raw = try await client.send(request)
    try expect(raw.statusCode == 403 && raw.body == Data("error-body".utf8) && raw.url == endpoint, "Raw HTTP error response retained")
    try expect(raw.header(named: "set-cookie") == "fixture_response=one; Path=/; Secure", "Error-response Set-Cookie retained")
    try expect(raw.header(named: "x-trace") == "trace-value", "Case-insensitive response headers")
    let sent = fixture.snapshot().requests
    try expect(sent.count == 1 && sent[0].value(forHTTPHeaderField: "Cookie") == "same=path; same=root", "Explicit cookie preserved without shared cookie")
    try expect(!sent[0].httpShouldHandleCookies, "Per-request automatic cookies disabled")
    try expect(!(HTTPCookieStorage.shared.cookies(for: endpoint) ?? []).contains { $0.name == "fixture_response" }, "Response cookie not saved to shared jar")

    fixture.configure(.response(URLResponse(url: endpoint, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data()))
    try await expectError(PiliHTTPClientError.invalidResponse, "Non-HTTP response rejected") { _ = try await client.send(request) }
    fixture.configure(.error(.timedOut))
    try await expectError(PiliHTTPClientError.transport(code: URLError.timedOut.rawValue), "Transport timeout code retained") { _ = try await client.send(request) }
    try expect(fixture.snapshot().requests.count == 1, "No implicit application retry")
    fixture.configure(.error(.cancelled))
    try await expectCancellation { _ = try await client.send(request) }

    fixture.configure(.hold)
    for url in ["http://api.bilibili.com/", "https://user:password@api.bilibili.com/", "file:///tmp/test"] {
      try await expectError(PiliHTTPClientError.invalidRequest, "Invalid transport URL never sent") {
        _ = try await client.send(URLRequest(url: URL(string: url)!))
      }
    }
    try expect(fixture.snapshot().requests.isEmpty, "Rejected requests never reached URLSession")
    let beforeStart = Task { try await client.send(request) }
    beforeStart.cancel()
    try await expectCancellation { _ = try await beforeStart.value }
    try expect(fixture.snapshot().requests.isEmpty, "Pre-cancellation sends no request")
    let pending = Task { try await client.send(request) }
    try await waitFor { fixture.snapshot().requests.count == 1 }
    pending.cancel()
    try await expectCancellation { _ = try await pending.value }
    try await waitFor { fixture.snapshot().stops > 0 }
    try expect(fixture.snapshot().requests.count == 1, "Cancellation stops underlying URLSession request")

    // Directly exercise the real stateless delegate. URLProtocol does not
    // reproduce CFNetwork redirects; this is not a live redirect integration test.
    let redirectSession = URLSession(configuration: .ephemeral)
    defer { redirectSession.invalidateAndCancel() }
    let redirectTask = redirectSession.dataTask(with: request)
    let delegate = PiliHTTPRedirectDelegate()
    let decision: URLRequest? = await withCheckedContinuation { continuation in
      delegate.urlSession(redirectSession, task: redirectTask,
        willPerformHTTPRedirection: HTTPURLResponse(url: endpoint, statusCode: 302, httpVersion: nil,
                                                    headerFields: ["Location": "https://other.example/"])!,
        newRequest: URLRequest(url: URL(string: "https://other.example/")!)) {
          continuation.resume(returning: $0)
        }
    }
    try expect(decision == nil, "Redirect delegate refuses forwarding")

    fixture.configure(rawReply(#"{"code":0,"data":{"list":[{"keyword":"native","recommend_reason":"a·b"}]}}"#))
    let service = PiliNativeSearchTrendingService(client: client)
    async let first = service.keywords(headers: ["Cookie": "account=A"])
    async let second = service.keywords(headers: ["Cookie": "account=B"])
    let (one, two) = try await (first, second)
    try expect(one == two && one.first?.keyword == "native" && one.first?.reason == "a b", "Real URLSession -> native decoder -> domain")
    try expect(Set(fixture.snapshot().requests.compactMap { $0.value(forHTTPHeaderField: "Cookie") }) == ["account=A", "account=B"], "Concurrent explicit contexts stay separate")
    fixture.configure(rawReply(#"{"code":-101,"message":"expired"}"#))
    try await expectError(PiliSearchTrendingError.api(code: -101, message: "expired"), "Service preserves API failure") { _ = try await service.keywords(headers: [:]) }
    fixture.configure(.hold)
    let serviceTask = Task { try await service.keywords(headers: [:]) }
    try await waitFor { fixture.snapshot().requests.count == 1 }
    serviceTask.cancel()
    try await expectCancellation { _ = try await serviceTask.value }
  }

  static func main() async throws {
    try requestChecks()
    try await decoderChecks()
    try await transportChecks()
    print("\(checks) native HTTP checks passed")
  }
}
