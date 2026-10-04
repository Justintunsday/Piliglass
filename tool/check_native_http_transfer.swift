import Foundation

private struct CheckFailure: Error { let message: String }
private struct Fixture: Decodable, Sendable {
  let id: String, wireValues: [String], statusCode: Int, mode: String, bodyBytes: Int
}
private struct Observation: Encodable, Sendable {
  let id: String, wireValues: [String], foundationValues: [String], cookieSource: String
  let statusCode: Int?, headCount: Int, outcomeReturned: Bool, completedBodyBytes: Int
  let transportErrorCode: Int?, cancelled: Bool, released: Bool
}
private struct Report: Encodable {
  var status = "failed", checks = 0, observations: [Observation] = [], shapes: [String: String] = [:]
  var reason: String?
}

private actor HeadObserver {
  var count = 0
  var transfer: PiliURLSessionHTTPTransfer?
  let cancelAfterHead: Bool
  init(cancelAfterHead: Bool) { self.cancelAfterHead = cancelAfterHead }
  func bind(_ transfer: PiliURLSessionHTTPTransfer) { self.transfer = transfer }
  func received(_ head: PiliHTTPResponseHead) {
    count += 1
    if cancelAfterHead { transfer?.cancel() }
  }
  func release() { transfer = nil }
}

@MainActor
private final class WeakTransferReference {
  weak var value: PiliURLSessionHTTPTransfer?
  init(_ transfer: PiliURLSessionHTTPTransfer?) { value = transfer }
}

// Only this URLProtocol probe synthesizes raw Foundation value shapes. The
// loopback observations below come from actual HTTP fields and production code.
private final class ShapeResponse: HTTPURLResponse, @unchecked Sendable {
  override var allHeaderFields: [AnyHashable: Any] {
    switch url?.query {
    case "limit=14": return ["Set-Cookie": NSNumber(value: 9)]
    case "limit=15": return ["Set-Cookie": ["array=one", "array=two"]]
    case "limit=16": return ["Set-Cookie": "first=one", "set-cookie": "second=two"]
    default: return ["Set-Cookie": "protocol=retained; Path=/"]
    }
  }
}
private final class ShapeProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.bilibili.com" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = ShapeResponse(url: request.url!, statusCode: request.url?.query == "limit=11" ? 403 : 200,
                                httpVersion: "HTTP/1.1", headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(repeating: 120, count: 1024))
    if request.url?.query != "limit=12" { client?.urlProtocolDidFinishLoading(self) }
  }
  override func stopLoading() {}
}

@MainActor
private final class ContextTransport: PiliBridgeMethodTransport {
  typealias Reply = @Sendable (Result<PiliBridgeValue, PiliBridgeInvocationError>) -> Void
  var methods: [String] = [], arguments: [[String: PiliBridgeValue]?] = [], replies: [Reply] = []
  var terminalState = "finished", holdTerminal = false
  func invoke(_ method: String, arguments values: [String: PiliBridgeValue]?, completion: @escaping Reply) {
    methods.append(method); arguments.append(values); replies.append(completion)
    if method == "prepareNativeHTTPRequest", case .string(let requestID) = values?["requestID"],
       case .integer(let limit) = values?["limit"] {
      completion(.success(.dictionary([
        "state": .string("prepared"), "requestID": .string(requestID), "leaseID": .string(UUID().uuidString.lowercased()),
        "url": .string("https://api.bilibili.com/x/v2/search/trending/ranking?limit=\(limit)"),
        "method": .string("GET"), "headers": .dictionary([:]), "revision": .integer(1), "generation": .integer(1),
        "limit": .integer(limit), "executionAllowed": .bool(false),
      ])))
    } else if !holdTerminal {
      completion(.success(Self.receipt(method == "abandonNativeHTTPRequest" ? "abandoned" : terminalState)))
    }
  }
  static func receipt(_ state: String) -> PiliBridgeValue {
    .dictionary(["state": .string(state), "cookiesSaved": .bool(false), "cookieCount": .integer(0), "executionAllowed": .bool(false)])
  }
}

@main @MainActor
private struct NativeHTTPTransferChecks {
  static var checks = 0
  static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
    checks += 1
  }
  static func until(_ message: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<400 {
      if await condition() { return }
      await Task.yield(); try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CheckFailure(message: "Timed out: \(message)")
  }
  static func configuration() -> URLSessionConfiguration {
    let result = URLSessionConfiguration.ephemeral
    result.httpCookieStorage = nil; result.httpShouldSetCookies = false; result.urlCredentialStorage = nil
    result.urlCache = nil; result.timeoutIntervalForRequest = 5; result.timeoutIntervalForResource = 5
    return result
  }
  static func cookies(_ head: PiliHTTPResponseHead?) -> (String, [String]) {
    guard let head else { return ("none", []) }
    switch head.cookieFields {
    case .foundationCombined(let values): return ("foundationCombined", values)
    case .unsupported: return ("unsupported", [])
    }
  }
  static func perform(
    _ fixture: Fixture, base: URL, session: URLSession, directory: URL
  ) async throws -> (Observation, PiliHTTPTransferOutcome) {
    let observer = HeadObserver(cancelAfterHead: fixture.mode == "pending")
    var request = URLRequest(url: base.appendingPathComponent(fixture.id))
    request.httpShouldHandleCookies = false
    var primitive: PiliURLSessionHTTPTransfer? = PiliURLSessionHTTPTransfer(session: session, request: request, onHead: { head in
      Task { await observer.received(head) }
    })
    let weakTransfer = WeakTransferReference(primitive)
    await observer.bind(primitive!)
    let result: PiliHTTPTransferOutcome
    if fixture.mode == "no-head" {
      let running = Task { [active = primitive!] in await active.run() }
      let marker = directory.appendingPathComponent("seen-\(fixture.id)")
      try await until("server received no-head request") { FileManager.default.fileExists(atPath: marker.path) }
      primitive!.cancel()
      result = await running.value
    } else {
      result = await primitive!.run()
    }
    if result.head != nil { try await until("head callback \(fixture.id)") { await observer.count == 1 } }
    let headCount = await observer.count
    try expect(headCount == (fixture.mode == "no-head" ? 0 : 1), "Exactly one original response head: \(fixture.id)")
    if fixture.mode == "pending" || fixture.mode == "no-head" {
      try expect(result.body == .failure(.cancelled) && result.transportErrorCode == URLError.cancelled.rawValue,
                 "Actual -999 completion retains cancellation: \(fixture.id)")
    } else if fixture.mode == "eof" {
      guard case .failure(.client(.transport)) = result.body else { throw CheckFailure(message: "Early EOF did not fail transfer") }
      try expect(result.head != nil && result.transportErrorCode != nil, "Transport failure retains its received head")
    } else {
      try expect(try result.body.get().count == fixture.bodyBytes, "Complete body bytes: \(fixture.id)")
    }
    if let head = result.head {
      try expect(head.statusCode == fixture.statusCode && head.url == request.url, "Original status/URL preserved: \(fixture.id)")
    }
    let duplicate = await primitive!.run()
    try expect(duplicate.head == nil && duplicate.body == .failure(.client(.invalidRequest)), "Second run cannot send or complete original twice")
    await observer.release(); primitive = nil
    try await until("released production transfer \(fixture.id)") { weakTransfer.value == nil }
    let representation = cookies(result.head)
    let count = (try? result.body.get().count) ?? 0
    return (Observation(id: fixture.id, wireValues: fixture.wireValues, foundationValues: representation.1,
      cookieSource: representation.0, statusCode: result.head?.statusCode, headCount: headCount, outcomeReturned: true,
      completedBodyBytes: count, transportErrorCode: result.transportErrorCode,
      cancelled: result.body == .failure(.cancelled), released: weakTransfer.value == nil), result)
  }
  static func protocolOutcome(_ limit: Int, session: URLSession) async throws -> PiliHTTPTransferOutcome {
    let url = URL(string: "https://api.bilibili.com/x/v2/search/trending/ranking?limit=\(limit)")!
    let observer = HeadObserver(cancelAfterHead: limit == 12)
    let primitive = PiliURLSessionHTTPTransfer(session: session, request: URLRequest(url: url), onHead: { head in
      Task { await observer.received(head) }
    })
    await observer.bind(primitive)
    let outcome = await primitive.run()
    try await until("URLProtocol head") { await observer.count == 1 }
    await observer.release()
    return outcome
  }
  nonisolated static func waitForFactory(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 3) == .success
  }
  static func installationRaceChecks(base: URL, session: URLSession) async throws {
    for cancelRunningTask in [false, true] {
      let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
      var primitive: PiliURLSessionHTTPTransfer? = PiliURLSessionHTTPTransfer(
        session: session, request: URLRequest(url: base.appendingPathComponent("must-not-send-install")),
        makeTask: { session, request in
          let task = session.dataTask(with: request)
          ready.signal()
          _ = release.wait(timeout: .now() + 6)
          return task
        }
      )
      let weakTransfer = WeakTransferReference(primitive)
      let running = Task.detached { [active = primitive!] in await active.run() }
      defer { release.signal() }
      let entered = await Task.detached { waitForFactory(ready) }.value
      try expect(entered, "Real suspended data task reached pre-install factory window")
      if cancelRunningTask { running.cancel() } else { primitive!.cancel() }
      release.signal()
      let outcome = await running.value
      try expect(outcome.head == nil && outcome.body == .failure(.cancelled) && outcome.transportErrorCode == nil,
                 "Cancellation during task creation settles without resuming task or inventing completion code")
      primitive = nil
      try await until("cancelled suspended task released") {
        await withCheckedContinuation { continuation in
          session.getAllTasks { tasks in continuation.resume(returning: tasks.isEmpty) }
        }
      }
      try await until("pre-install transfer released") { weakTransfer.value == nil }
      try expect(weakTransfer.value == nil, "Controlled install cancellation releases delegate and continuation")
    }
  }
  static func finalizationChecks(noHead: PiliHTTPTransferOutcome, report: inout Report) async throws {
    let config = configuration(); config.protocolClasses = [ShapeProtocol.self]
    let session = URLSession(configuration: config, delegate: PiliHTTPRedirectDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    for limit in [10, 11, 12, 14, 15, 16] {
      let outcome = try await protocolOutcome(limit, session: session)
      let shape = cookies(outcome.head)
      report.shapes[String(limit)] = shape.0
      try expect(shape.0 == ([14, 16].contains(limit) ? "unsupported" : "foundationCombined"),
                 "Unknown/duplicate raw values are unsupported; arrays never upgrade wire provenance")
      if limit == 12 { try expect(outcome.body == .failure(.cancelled) && outcome.head != nil, "Actual HTTPS protocol transfer retains head after cancel") }
      let transport = ContextTransport()
      let provider = PiliFlutterHTTPRequestContextProvider(transport: transport, terminalTimeoutNanoseconds: 50_000_000)
      defer { provider.dispose() }
      let context = try await provider.prepare(.searchTrending(limit: limit))
      let finalizer = PiliHTTPRequestHeaderFinalizer(provider: provider)
      if [14, 16].contains(limit) {
        do { _ = try await finalizer.finalize(context, outcome: outcome); throw CheckFailure(message: "Unsupported Cookie fields accepted") }
        catch PiliHTTPRequestContextError.invalidResponse { checks += 1 }
        try expect(transport.methods == ["prepareNativeHTTPRequest", "abandonNativeHTTPRequest"], "Unsupported raw head only abandons")
      } else {
        _ = try await finalizer.finalize(context, outcome: outcome)
        try expect(transport.methods == ["prepareNativeHTTPRequest", "finishNativeHTTPRequest"], "Received head finishes before body/status interpretation")
        guard case .dictionary(let metadata) = transport.arguments.last!?["response"] else { throw CheckFailure(message: "Missing terminal metadata") }
        try expect(metadata["cookieSource"] == .string("foundationCombined") &&
          metadata["setCookieValues"] == .array(shape.1.map(PiliBridgeValue.string)), "Raw Cookie order/provenance forwarded unchanged")
      }
    }
    let noHeadTransport = ContextTransport()
    let noHeadProvider = PiliFlutterHTTPRequestContextProvider(transport: noHeadTransport)
    defer { noHeadProvider.dispose() }
    let emptyContext = try await noHeadProvider.prepare(.searchTrending(limit: 10))
    _ = try await PiliHTTPRequestHeaderFinalizer(provider: noHeadProvider).finalize(emptyContext, outcome: noHead)
    try expect(noHeadTransport.methods == ["prepareNativeHTTPRequest", "abandonNativeHTTPRequest"], "Real pre-head cancellation only abandons")

    let outcome = try await protocolOutcome(10, session: session)
    let cancelledTransport = ContextTransport()
    let cancelledProvider = PiliFlutterHTTPRequestContextProvider(transport: cancelledTransport)
    defer { cancelledProvider.dispose() }
    let cancelledContext = try await cancelledProvider.prepare(.searchTrending(limit: 10))
    let cancelledFinalizer = PiliHTTPRequestHeaderFinalizer(provider: cancelledProvider)
    let preCancelled = Task { try await cancelledFinalizer.finalize(cancelledContext, outcome: outcome) }
    preCancelled.cancel()
    let settled = try await preCancelled.value
    try expect(settled.outcome == .finished && cancelledTransport.methods == ["prepareNativeHTTPRequest", "finishNativeHTTPRequest"],
               "Already cancelled caller still finalizes received headers exactly once")

    let waitingTransport = ContextTransport()
    let waitingProvider = PiliFlutterHTTPRequestContextProvider(transport: waitingTransport, terminalTimeoutNanoseconds: 1_000_000_000)
    defer { waitingProvider.dispose() }
    let waitingContext = try await waitingProvider.prepare(.searchTrending(limit: 10))
    waitingTransport.holdTerminal = true
    let waitingFinalizer = PiliHTTPRequestHeaderFinalizer(provider: waitingProvider)
    let waiting = Task { try await waitingFinalizer.finalize(waitingContext, outcome: outcome) }
    try await until("actual header finish awaits ack") { waitingTransport.methods.count == 2 }
    waiting.cancel()
    waitingTransport.replies[1](.success(ContextTransport.receipt("finished")))
    let completed = try await waiting.value
    try expect(completed.outcome == .finished && waitingTransport.methods == ["prepareNativeHTTPRequest", "finishNativeHTTPRequest"],
               "Caller cancellation while awaiting header finish ack cannot switch to abandon or lose ack")

    for hold in [false, true] {
      let transport = ContextTransport(); transport.terminalState = "unknown"
      let provider = PiliFlutterHTTPRequestContextProvider(transport: transport, terminalTimeoutNanoseconds: 20_000_000)
      defer { provider.dispose() }
      let context = try await provider.prepare(.searchTrending(limit: 10))
      transport.holdTerminal = hold
      let finalizer = PiliHTTPRequestHeaderFinalizer(provider: provider)
      if hold {
        do { _ = try await finalizer.finalize(context, outcome: outcome); throw CheckFailure(message: "Absent terminal ack did not timeout") }
        catch PiliHTTPRequestContextError.terminalTimeout { checks += 1 }
        transport.replies[1](.success(ContextTransport.receipt("finished")))
      } else {
        let receipt = try await finalizer.finalize(context, outcome: outcome)
        try expect(receipt.outcome == .unknown, "Unknown ack remains explicit")
      }
      _ = try await finalizer.finalize(context, outcome: outcome)
      try expect(transport.methods == ["prepareNativeHTTPRequest", "finishNativeHTTPRequest"], "Unknown/late ack never replays terminal or chooses fallback abandon")
    }
  }
  static func main() async {
    var report = Report()
    do {
      guard CommandLine.arguments.count == 4, let base = URL(string: CommandLine.arguments[1]),
            base.scheme == "http", base.host == "127.0.0.1", base.port != nil, base.path == "/",
            base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
        throw CheckFailure(message: "Fixture permits only supplied IPv4 loopback HTTP endpoint")
      }
      let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
      let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
      let session = URLSession(configuration: configuration(), delegate: PiliHTTPRedirectDelegate(), delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      var noHead: PiliHTTPTransferOutcome?
      for fixture in fixtures where !fixture.id.hasPrefix("concurrent-") {
        let result = try await perform(fixture, base: base, session: session, directory: reportURL.deletingLastPathComponent())
        report.observations.append(result.0)
        if fixture.mode == "no-head" { noHead = result.1 }
      }
      let cancelled = fixtures.first { $0.id == "concurrent-cancel" }!
      let completed = fixtures.first { $0.id == "concurrent-complete" }!
      async let one = perform(cancelled, base: base, session: session, directory: reportURL.deletingLastPathComponent())
      async let two = perform(completed, base: base, session: session, directory: reportURL.deletingLastPathComponent())
      let pair = try await (one, two)
      report.observations.append(contentsOf: [pair.0.0, pair.1.0])
      try expect(pair.0.0.cancelled && !pair.1.0.cancelled && pair.1.0.completedBodyBytes == completed.bodyBytes,
                 "Shared session isolates concurrent cancellation from successful response")
      try expect(pair.0.0.foundationValues != pair.1.0.foundationValues, "Concurrent heads do not cross request state")
      let preCancelled = PiliURLSessionHTTPTransfer(session: session, request: URLRequest(url: base.appendingPathComponent("must-not-send")))
      preCancelled.cancel()
      let early = await preCancelled.run()
      try expect(early.head == nil && early.body == .failure(.cancelled) && early.transportErrorCode == nil,
                 "Cancel-install latch creates no task or invented transport code before start")
      let external = PiliURLSessionHTTPClient()
      let rejected = await external.transfer(URLRequest(url: base))
      try expect(rejected.head == nil && rejected.body == .failure(.client(.invalidRequest)), "External client still rejects HTTP")
      try await installationRaceChecks(base: base, session: session)
      guard let noHead else { throw CheckFailure(message: "No pre-head outcome") }
      try await finalizationChecks(noHead: noHead, report: &report)
      report.status = "passed"
    } catch { report.reason = (error as? CheckFailure)?.message ?? String(describing: error) }
    report.checks = checks
    do {
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments.last!), options: .atomic)
    } catch { print("Unable to write transfer report: \(error)"); exit(1) }
    print("\(checks) production native HTTP transfer checks \(report.status)")
    if let reason = report.reason { print(reason) }
    if report.status != "passed" { exit(1) }
  }
}
