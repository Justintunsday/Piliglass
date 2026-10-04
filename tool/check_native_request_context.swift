import Foundation

private struct CheckFailure: Error { let message: String }

@MainActor
private final class FakeTransport: PiliBridgeMethodTransport {
  struct Call: Sendable {
    let method: String
    let arguments: [String: PiliBridgeValue]?
  }
  typealias Reply = @Sendable (Result<PiliBridgeValue, PiliBridgeInvocationError>) -> Void
  var calls: [Call] = []
  var replies: [Reply] = []
  var immediate: (@MainActor (Call) -> Result<PiliBridgeValue, PiliBridgeInvocationError>?)?

  func invoke(_ method: String, arguments: [String: PiliBridgeValue]?, completion: @escaping Reply) {
    let call = Call(method: method, arguments: arguments)
    calls.append(call); replies.append(completion)
    if let result = immediate?(call) { completion(result) }
  }
  func complete(_ index: Int, _ result: Result<PiliBridgeValue, PiliBridgeInvocationError>, background: Bool = false) {
    let reply = replies[index]
    if background { DispatchQueue.global().async { reply(result) } }
    else { reply(result) }
  }
  var terminalCalls: [Call] { calls.filter { $0.method != "prepareNativeHTTPRequest" } }
  func dropReplies() { replies.removeAll() }
}

@MainActor
private final class Outcome<Value: Sendable> { var result: Result<Value, Error>? }

@MainActor
private final class WeakProviderReference {
  weak var value: PiliFlutterHTTPRequestContextProvider?
  init(_ provider: PiliFlutterHTTPRequestContextProvider?) { value = provider }
}

@main @MainActor
private struct NativeRequestContextChecks {
  static var checks = 0
  static let requestID = "a0000000-0000-4000-8000-000000000001"
  static let leaseID = "b0000000-0000-4000-8000-000000000002"
  static let endpoint = URL(string: "https://api.bilibili.com/x/v2/search/trending/ranking?limit=10")!

  static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
    checks += 1
  }
  static func until(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield(); try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CheckFailure(message: "Timed out: \(message)")
  }
  static func drain() async throws {
    for _ in 0..<5 { await Task.yield() }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  static func value<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
    let outcome = Outcome<Value>()
    let task = Task {
      do { outcome.result = .success(try await operation()) }
      catch { outcome.result = .failure(error) }
    }
    defer { task.cancel() }
    try await until("operation completed") { outcome.result != nil }
    return try outcome.result!.get()
  }
  static func error(
    _ operation: @escaping @MainActor () async throws -> Void,
    _ matches: (Error) -> Bool,
    _ message: String
  ) async throws {
    do { try await value(operation) }
    catch { try expect(matches(error), "\(message): unexpected \(error)"); return }
    throw CheckFailure(message: "\(message): error expected")
  }
  static func fields(requestID: String = "a0000000-0000-4000-8000-000000000001", limit: Int = 10) -> [String: PiliBridgeValue] {
    ["state": .string("prepared"), "requestID": .string(requestID), "leaseID": .string(leaseID),
     "url": .string("https://api.bilibili.com/x/v2/search/trending/ranking?limit=\(limit)"),
     "method": .string("GET"), "headers": .dictionary(["cookie": .string("same=path; same=root"), "env": .string("prod")]),
     "revision": .integer(9_007_199_254_740_993), "generation": .integer(7), "limit": .integer(Int64(limit)),
     "executionAllowed": .bool(false)]
  }
  static func receipt(_ state: String = "finished", saved: Bool = false, count: Int = 0) -> PiliBridgeValue {
    .dictionary(["state": .string(state), "cookiesSaved": .bool(saved), "cookieCount": .integer(Int64(count)),
                 "executionAllowed": .bool(false)])
  }
  static func automatic() -> FakeTransport {
    let transport = FakeTransport()
    transport.immediate = { call in
      if call.method == "prepareNativeHTTPRequest", case .string(let id) = call.arguments?["requestID"],
         case .integer(let limit) = call.arguments?["limit"] {
        return .success(.dictionary(fields(requestID: id, limit: Int(limit))))
      }
      return .success(receipt(call.method == "finishNativeHTTPRequest" ? "finished" : "abandoned"))
    }
    return transport
  }
  static func provider(
    _ transport: FakeTransport, capacity: Int = 32, timeout: UInt64 = 100_000_000
  ) -> PiliFlutterHTTPRequestContextProvider {
    PiliFlutterHTTPRequestContextProvider(transport: transport, maxActiveContexts: capacity,
                                         terminalTimeoutNanoseconds: timeout)
  }
  static func response(_ context: PiliHTTPRequestContext, status: Int = 403) -> PiliHTTPRequestResponseCookies {
    PiliHTTPRequestResponseCookies(url: context.request.url, statusCode: status,
      cookieSource: .foundationCombined, setCookieValues: ["id=one; Path=/", "id=two; Path=/x"])
  }
  static func main() async {
    do {
      try await codecChecks(); try await ordinaryChecks(); try await prepareCancellationChecks()
      try await invalidPrepareChecks(); try await terminalChecks(); try await capacityAndDisposalChecks()
      print("\(checks) native request context checks passed")
    } catch {
      print("FAIL native request context checks: \(error)"); exit(1)
    }
  }

  static func codecChecks() async throws {
    for limit in [0, 31] {
      try await error({ _ = try PiliHTTPRequestContextBridgeCodec.prepareArguments(requestID: requestID,
        purpose: .searchTrending(limit: limit)) }, { ($0 as? PiliHTTPRequestContextError) == .invalidRequest },
        "Unsupported prepare limit never becomes a request")
    }
    let context = try PiliHTTPRequestContextBridgeCodec.decodePrepared(.dictionary(fields()), requestID: requestID,
                                                                       purpose: .searchTrending(limit: 10))
    try expect(context.request.url == endpoint && context.request.method == "GET" && context.limit == 10,
               "Prepared descriptor retains exact endpoint, GET and limit")
    try expect(context.request.headers["cookie"] == "same=path; same=root" && context.revision == 9_007_199_254_740_993
      && context.generation == 7 && !context.executionAllowed, "Cookie ordering, large integer and disabled gate retained")
    let crossed = await Task.detached { context }.value
    try expect(crossed == context, "Owned Domain context crosses tasks under complete concurrency")
    var uppercase = fields(requestID: requestID.uppercased())
    uppercase["leaseID"] = .string(leaseID.uppercased())
    let normalized = try PiliHTTPRequestContextBridgeCodec.decodePrepared(.dictionary(uppercase), requestID: requestID,
                                                                         purpose: .searchTrending(limit: 10))
    try expect(UUID(uuidString: normalized.requestID) == UUID(uuidString: requestID), "UUID comparison handles case")
    let invalid: [(String, PiliBridgeValue)] = [
      ("state", .string("success")), ("requestID", .string(leaseID)), ("leaseID", .string("invalid")),
      ("method", .string("POST")), ("limit", .bool(true)), ("limit", .double(10)), ("limit", .string("10")),
      ("limit", .integer(11)), ("revision", .bool(false)), ("revision", .double(1)), ("revision", .integer(-1)),
      ("generation", .integer(0)), ("generation", .string("7")), ("executionAllowed", .bool(true)),
      ("executionAllowed", .integer(0)), ("executionAllowed", .string("false")), ("headers", .array([])),
      ("headers", .dictionary(["cookie": .integer(1)])), ("headers", .dictionary(["x": .string("bad\r\nheader")])),
      ("headers", .dictionary(["bad name": .string("value")])), ("headers", .dictionary(["host": .string("api.bilibili.com")])),
      ("headers", .dictionary(["Cookie": .string("one"), "cookie": .string("two")])),
    ]
    for (key, bad) in invalid {
      var payload = fields(); payload[key] = bad
      try await error({ _ = try PiliHTTPRequestContextBridgeCodec.decodePrepared(.dictionary(payload), requestID: requestID,
        purpose: .searchTrending(limit: 10)) }, { ($0 as? PiliHTTPRequestContextError) == .invalidResponse },
        "Strict prepared field \(key)=\(bad)")
    }
    for url in ["http://api.bilibili.com/x/v2/search/trending/ranking?limit=10",
      "https://user@api.bilibili.com/x/v2/search/trending/ranking?limit=10",
      "https://other.example/x/v2/search/trending/ranking?limit=10",
      "https://api.bilibili.com/other?limit=10",
      "https://api.bilibili.com/x/v2/search/trending/ranking?limit=10&limit=10",
      "https://api.bilibili.com/x/v2/search/trending/ranking?limit=10#fragment"] {
      var payload = fields(); payload["url"] = .string(url)
      try await error({ _ = try PiliHTTPRequestContextBridgeCodec.decodePrepared(.dictionary(payload), requestID: requestID,
        purpose: .searchTrending(limit: 10)) }, { ($0 as? PiliHTTPRequestContextError) == .invalidResponse }, "Exact URL whitelist")
    }
    var missing = fields(); missing.removeValue(forKey: "generation")
    try await error({ _ = try PiliHTTPRequestContextBridgeCodec.decodePrepared(.dictionary(missing), requestID: requestID,
      purpose: .searchTrending(limit: 10)) }, { ($0 as? PiliHTTPRequestContextError) == .invalidResponse }, "Incomplete snapshot")
    for state in ["finished", "abandoned", "expired", "consumed", "unknown", "revoked", "closed"] {
      let decoded = try PiliHTTPRequestContextBridgeCodec.decodeReceipt(receipt(state))
      try expect(decoded.outcome.rawValue == state && !decoded.cookiesSaved && decoded.cookieCount == 0, "Receipt \(state)")
    }
    let partial = try PiliHTTPRequestContextBridgeCodec.decodeReceipt(receipt("revoked", saved: true, count: 2))
    try expect(partial.cookiesSaved && partial.cookieCount == 2, "Revoked ack can report already executed Cookie mutation")
    for payload in [PiliBridgeValue.null, .dictionary([:]), .dictionary(["state": .string("invented")]),
      .dictionary(["state": .string("finished"), "cookiesSaved": .integer(0), "cookieCount": .integer(0), "executionAllowed": .bool(false)]),
      .dictionary(["state": .string("finished"), "cookiesSaved": .bool(false), "cookieCount": .double(0), "executionAllowed": .bool(false)]),
      .dictionary(["state": .string("finished"), "cookiesSaved": .bool(false), "cookieCount": .integer(-1), "executionAllowed": .bool(false)]),
      .dictionary(["state": .string("finished"), "cookiesSaved": .bool(true), "cookieCount": .integer(0), "executionAllowed": .bool(false)]),
      .dictionary(["state": .string("finished"), "cookiesSaved": .bool(false), "cookieCount": .integer(1), "executionAllowed": .bool(false)])] {
      try await error({ _ = try PiliHTTPRequestContextBridgeCodec.decodeReceipt(payload) },
        { ($0 as? PiliHTTPRequestContextError) == .invalidResponse }, "Strict receipt shape/types")
    }
    let arguments = try PiliHTTPRequestContextBridgeCodec.finishArguments(context: context, response: response(context))
    guard case .dictionary(let metadata) = arguments["response"] else { throw CheckFailure(message: "Missing response metadata") }
    try expect(metadata["statusCode"] == .integer(403) && metadata["cookieSource"] == .string("foundationCombined") &&
      metadata["setCookieValues"] == .array([.string("id=one; Path=/"), .string("id=two; Path=/x")]),
      "Finish sends original Cookie fields and provenance before status interpretation")

    // The production copier deliberately drops non-String raw dictionary keys.
    // This fixture documents its boundary; the strict decoder never saw that key.
    let raw = NSMutableDictionary(dictionary: fields().mapValues(\.codecValue))
    raw[NSNumber(value: 9)] = "ignored legacy key"
    let owned = try PiliBridgeValue(codecValue: raw)
    raw["method"] = "POST"
    let copied = try PiliHTTPRequestContextBridgeCodec.decodePrepared(owned, requestID: requestID,
                                                                     purpose: .searchTrending(limit: 10))
    try expect(copied.request.method == "GET", "Raw copier owns values and retains known legacy non-String key boundary")
  }

  static func ordinaryChecks() async throws {
    let transport = automatic(), active = provider(transport)
    defer { active.dispose() }
    let context = try await value { try await active.prepare(.searchTrending(limit: 10)) }
    try expect(transport.calls[0].method == "prepareNativeHTTPRequest" &&
      transport.calls[0].arguments?["purpose"] == .string("searchTrending") &&
      transport.calls[0].arguments?["limit"] == .integer(10), "Real invoker uses exact prepare command")
    try expect(context.requestID == context.requestID.lowercased() && UUID(uuidString: context.requestID) != nil,
               "Client generated canonical UUID before dispatch")
    let done = try await value { try await active.finish(context, response: response(context)) }
    try expect(done.outcome == .finished && active.activeContextCount == 0, "Synchronous prepare/terminal callbacks complete and release")
    try expect(transport.terminalCalls.count == 1 && transport.terminalCalls[0].method == "finishNativeHTTPRequest",
               "Normal finish dispatches exactly once")
    let replay = try await value { try await active.abandon(context) }
    try expect(replay.outcome == .consumed && transport.terminalCalls.count == 1, "Finished context cannot be abandoned again")
    let valid = try await value { try await active.prepare(.searchTrending(limit: 10)) }
    let forged = PiliHTTPRequestContext(requestID: valid.requestID, leaseID: UUID().uuidString.lowercased(),
      request: valid.request, revision: valid.revision, generation: valid.generation, limit: valid.limit)
    try await error({ _ = try await active.abandon(forged) },
      { ($0 as? PiliHTTPRequestContextError) == .invalidRequest }, "Wrong token cannot consume original context")
    try expect(active.activeContextCount == 1 && transport.terminalCalls.count == 1, "Rejected token leaves valid registry entry")
    let legitimate = try await value { try await active.abandon(valid) }
    try expect(legitimate.outcome == .abandoned && transport.terminalCalls.count == 2, "Correct token remains usable after forged-token rejection")

    let background = FakeTransport(), other = provider(background)
    defer { other.dispose() }
    let preparing = Task { try await other.prepare(.searchTrending(limit: 10)) }
    try await until("background prepare") { background.calls.count == 1 }
    let id = background.calls[0].arguments!["requestID"]!
    guard case .string(let text) = id else { throw CheckFailure(message: "Missing generated request ID") }
    background.complete(0, .success(.dictionary(fields(requestID: text))), background: true)
    let received = try await value { try await preparing.value }
    let abandoning = Task { try await other.abandon(received) }
    try await until("background abandon") { background.calls.count == 2 }
    background.complete(1, .success(receipt("abandoned")), background: true)
    background.complete(1, .success(receipt("abandoned")), background: true)
    let abandoned = try await value { try await abandoning.value }
    try expect(abandoned.outcome == .abandoned, "Background and duplicate acknowledgements resume once")
  }

  static func prepareCancellationChecks() async throws {
    let transport = FakeTransport(), active = provider(transport)
    defer { active.dispose() }
    let early = Task { try await active.prepare(.searchTrending(limit: 10)) }; early.cancel()
    try await error({ _ = try await early.value }, { $0 is CancellationError }, "Pre-cancelled prepare")
    try expect(transport.calls.isEmpty, "Pre-cancellation allocates no request and sends nothing")
    let pending = Task { try await active.prepare(.searchTrending(limit: 10)) }
    try await until("pending prepare") { transport.calls.count == 1 }
    pending.cancel()
    try await error({ _ = try await pending.value }, { $0 is CancellationError }, "Cancellation ends Swift wait")
    try await until("independent abandon") { transport.terminalCalls.count == 1 }
    let sent = transport.calls[0].arguments!["requestID"]!
    try expect(transport.terminalCalls[0].method == "abandonNativeHTTPRequest" &&
      transport.terminalCalls[0].arguments == ["requestID": sent], "Cleanup survives cancellation without needing leaseID")
    guard case .string(let id) = sent else { throw CheckFailure(message: "Request ID missing") }
    transport.complete(0, .success(.dictionary(fields(requestID: id))))
    transport.complete(0, .success(.dictionary(fields(requestID: id))), background: true)
    transport.complete(1, .success(receipt("abandoned")))
    try await drain()
    try expect(transport.terminalCalls.count == 1 && active.activeContextCount == 0,
               "Late/duplicate prepare callbacks cannot recreate or re-finalize a cancelled lease")

    let racing = FakeTransport(), raceProvider = provider(racing)
    defer { raceProvider.dispose() }
    let race = Task { try await raceProvider.prepare(.searchTrending(limit: 10)) }
    try await until("callback/cancel race") { racing.calls.count == 1 }
    guard case .string(let raceID) = racing.calls[0].arguments?["requestID"] else { throw CheckFailure(message: "Missing race ID") }
    racing.complete(0, .success(.dictionary(fields(requestID: raceID))))
    race.cancel()
    try await error({ _ = try await race.value }, { $0 is CancellationError }, "Callback then cancellation before actor delivery")
    try await until("race cleanup") { racing.terminalCalls.count == 1 }
    racing.complete(1, .success(receipt("abandoned")))
    try await until("race released") { raceProvider.activeContextCount == 0 }
    try expect(racing.terminalCalls.count == 1, "Callback/cancel race has one cleanup")
  }

  static func invalidPrepareChecks() async throws {
    let failures: [(Result<PiliBridgeValue, PiliBridgeInvocationError>, PiliHTTPRequestContextError)] = [
      (.success(.dictionary(["state": .string("prepared")])), .invalidResponse),
      (.failure(.unavailable), .bridgeFailure(code: "unavailable")),
      (.failure(.invalidValue), .invalidResponse),
      (.failure(.platform(code: "wire", message: "not credentials")), .bridgeFailure(code: "wire")),
      (.success(.dictionary(["state": .string("error"), "code": .string("snapshotChanged"),
                            "executionAllowed": .bool(false)])), .serviceFailure(code: "snapshotChanged")),
    ]
    for (result, expected) in failures {
      let transport = FakeTransport(), active = provider(transport)
      defer { active.dispose() }
      let pending = Task { try await active.prepare(.searchTrending(limit: 10)) }
      try await until("bad prepare sent") { transport.calls.count == 1 }
      transport.complete(0, result)
      try await error({ _ = try await pending.value }, { ($0 as? PiliHTTPRequestContextError) == expected },
                      "Invalid/error prepare response maps to precise Domain failure")
      try await until("bad prepare cleanup") { transport.terminalCalls.count == 1 }
      try expect(transport.terminalCalls[0].arguments == ["requestID": transport.calls[0].arguments!["requestID"]!],
                 "Prepare failures clean local ID instead of trusting missing response token")
      transport.complete(1, .success(receipt("abandoned")))
      try await until("bad prepare released") { active.activeContextCount == 0 }
      try expect(transport.terminalCalls.count == 1, "Failed prepare has one terminal dispatch")
    }
  }

  static func terminalChecks() async throws {
    let transport = automatic(), active = provider(transport)
    defer { active.dispose() }
    let context = try await value { try await active.prepare(.searchTrending(limit: 10)) }
    let cancelled = Task { try await active.finish(context, response: response(context)) }; cancelled.cancel()
    let result = try await value { try await cancelled.value }
    try expect(result.outcome == .finished && transport.terminalCalls.count == 1,
               "Already cancelled caller still sends and awaits real finish")
    let abandonedContext = try await value { try await active.prepare(.searchTrending(limit: 10)) }
    let cancelledAbandon = Task { try await active.abandon(abandonedContext) }; cancelledAbandon.cancel()
    let abandoned = try await value { try await cancelledAbandon.value }
    try expect(abandoned.outcome == .abandoned && transport.terminalCalls.count == 2,
               "Already cancelled caller still sends and awaits real abandon")

    let held = automatic(), racing = provider(held)
    defer { racing.dispose() }
    let pair = try await value { try await racing.prepare(.searchTrending(limit: 10)) }
    held.immediate = nil
    let finishing = Task { try await racing.finish(pair, response: response(pair)) }
    try await until("finish claimed") { held.terminalCalls.count == 1 }
    finishing.cancel()
    let competing = try await value { try await racing.abandon(pair) }
    try expect(competing.outcome == .consumed && held.terminalCalls.count == 1,
               "Finish/abandon race claims before await")
    held.complete(1, .success(receipt()))
    let finished = try await value { try await finishing.value }
    try expect(finished.outcome == .finished, "Cancellation after dispatch cannot cancel independent terminal acknowledgement")

    let malformed = automatic(), preflight = provider(malformed)
    defer { preflight.dispose() }
    let prepared = try await value { try await preflight.prepare(.searchTrending(limit: 10)) }
    let wrong = PiliHTTPRequestResponseCookies(url: URL(string: "https://other.example/")!, statusCode: 200,
      cookieSource: .separatedFields, setCookieValues: [])
    try await error({ _ = try await preflight.finish(prepared, response: wrong) },
      { ($0 as? PiliHTTPRequestContextError) == .invalidRequest }, "Strict finish preflight")
    try await until("preflight abandon") { malformed.terminalCalls.count == 1 }
    try expect(malformed.terminalCalls[0].method == "abandonNativeHTTPRequest", "Preflight failure sends only abandon")

    let badAcknowledgements: [(PiliBridgeValue, PiliHTTPRequestContextError)] = [
      (.null, .invalidResponse), (.dictionary(["state": .string("invented")]), .invalidResponse),
      (.dictionary(["state": .string("error"), "code": .string("invalidArguments"), "executionAllowed": .bool(false)]),
       .serviceFailure(code: "invalidArguments")),
      (.dictionary(["state": .string("error"), "code": .string("leaseMismatch"), "executionAllowed": .bool(false)]),
       .serviceFailure(code: "leaseMismatch")),
      (.dictionary(["state": .string("error"), "code": .string("notPrepared"), "executionAllowed": .bool(false)]),
       .serviceFailure(code: "notPrepared")),
    ]
    for (acknowledgement, expected) in badAcknowledgements {
      let fake = automatic(), subject = provider(fake)
      defer { subject.dispose() }
      let snapshot = try await value { try await subject.prepare(.searchTrending(limit: 10)) }
      fake.immediate = { _ in .success(acknowledgement) }
      try await error({ _ = try await subject.finish(snapshot, response: response(snapshot)) },
        { ($0 as? PiliHTTPRequestContextError) == expected }, "Invalid or server preclaim acknowledgement mapping")
      _ = try await value { try await subject.abandon(snapshot) }
      try expect(fake.terminalCalls.count == 1 && subject.activeContextCount == 0,
                 "Bad terminal ack closes local gate; no automatic second finish/abandon (Dart TTL remains bounded fallback)")
    }

    let unknown = automatic(), unknownProvider = provider(unknown)
    defer { unknownProvider.dispose() }
    let unknownContext = try await value { try await unknownProvider.prepare(.searchTrending(limit: 10)) }
    unknown.immediate = { _ in .success(receipt("unknown")) }
    let unknownReceipt = try await value { try await unknownProvider.finish(unknownContext, response: response(unknownContext)) }
    _ = try await value { try await unknownProvider.abandon(unknownContext) }
    try expect(unknownReceipt.outcome == .unknown && unknown.terminalCalls.count == 1,
               "Valid unknown acknowledgement remains explicit and does not trigger another terminal command")

    let failedWire = automatic(), failedProvider = provider(failedWire)
    defer { failedProvider.dispose() }
    let failedContext = try await value { try await failedProvider.prepare(.searchTrending(limit: 10)) }
    failedWire.immediate = { _ in .failure(.platform(code: "terminal-wire", message: "offline")) }
    try await error({ _ = try await failedProvider.finish(failedContext, response: response(failedContext)) },
      { ($0 as? PiliHTTPRequestContextError) == .bridgeFailure(code: "terminal-wire") }, "Terminal transport error retains typed code")
    _ = try await value { try await failedProvider.abandon(failedContext) }
    try expect(failedWire.terminalCalls.count == 1 && failedProvider.activeContextCount == 0, "Transport failure does not retry or issue second terminal")

    let silent = automatic(), timeout = provider(silent, timeout: 20_000_000)
    defer { timeout.dispose() }
    let snapshot = try await value { try await timeout.prepare(.searchTrending(limit: 10)) }
    silent.immediate = nil
    try await error({ _ = try await timeout.finish(snapshot, response: response(snapshot)) },
      { ($0 as? PiliHTTPRequestContextError) == .terminalTimeout }, "Absent ack reaches actual production timeout")
    try expect(timeout.activeContextCount == 0 && silent.terminalCalls.count == 1,
               "Timeout releases Swift registry without claiming Dart mutation stopped")
    silent.complete(1, .success(receipt())); silent.complete(1, .success(receipt()), background: true)
    let afterTimeout = try await value { try await timeout.finish(snapshot, response: response(snapshot)) }
    try expect(afterTimeout.outcome == .consumed && silent.terminalCalls.count == 1, "Late ack cannot resume again or trigger replay")

    let dropping = FakeTransport()
    dropping.immediate = { [weak dropping] _ in dropping?.dropReplies(); return nil }
    let finalizer = PiliBridgeLeaseFinalizer(transport: dropping, requestID: requestID, timeoutNanoseconds: 20_000_000)
    guard let terminal = finalizer.start("abandonNativeHTTPRequest", arguments: ["requestID": .string(requestID)]) else {
      throw CheckFailure(message: "First finalizer claim failed")
    }
    try await until("drop callback after actual dispatch") { dropping.calls.count == 1 }
    try expect(dropping.replies.isEmpty, "Transport discards callback synchronously before acknowledgement timeout")
    try await error({ _ = try await terminal.value },
      { ($0 as? PiliBridgeLeaseFinalizationError) == .timeout }, "Timeout owns acknowledgement even when transport discards its callback")
    try expect(finalizer.start("abandonNativeHTTPRequest", arguments: ["requestID": .string(requestID)]) == nil &&
      dropping.calls.count == 1, "Timed-out raw finalizer cannot dispatch again")
  }

  static func capacityAndDisposalChecks() async throws {
    let transport = FakeTransport(), bounded = provider(transport, capacity: 1)
    let pending = Task { try await bounded.prepare(.searchTrending(limit: 10)) }
    try await until("bounded pending") { transport.calls.count == 1 }
    try await error({ _ = try await bounded.prepare(.searchTrending(limit: 10)) },
      { ($0 as? PiliHTTPRequestContextError) == .capacity }, "Pending contexts count toward capacity")
    try expect(transport.calls.count == 1 && bounded.activeContextCount == 1, "Capacity failure sends no second prepare")
    bounded.dispose()
    try await error({ _ = try await pending.value }, { $0 is CancellationError || ($0 as? PiliHTTPRequestContextError) == .disposed },
                    "Dispose cancels pending operation")
    try await until("dispose pending cleanup") { transport.terminalCalls.count == 1 }
    transport.complete(1, .success(receipt("abandoned")))
    try expect(bounded.activeContextCount == 0, "Dispose releases pending registry synchronously")

    let fake = automatic(), prepared = provider(fake, capacity: 1)
    let context = try await value { try await prepared.prepare(.searchTrending(limit: 10)) }
    try await error({ _ = try await prepared.prepare(.searchTrending(limit: 10)) },
      { ($0 as? PiliHTTPRequestContextError) == .capacity }, "Prepared contexts count toward capacity")
    prepared.dispose()
    try await until("dispose prepared cleanup") { fake.terminalCalls.count == 1 }
    try expect(fake.terminalCalls[0].method == "abandonNativeHTTPRequest" && prepared.activeContextCount == 0,
               "Dispose prepared context dispatches abandon and releases")
    try await error({ _ = try await prepared.prepare(.searchTrending(limit: 10)) },
      { ($0 as? PiliHTTPRequestContextError) == .disposed }, "Disposed provider cannot prepare")
    _ = context

    let held = automatic()
    var ending: PiliFlutterHTTPRequestContextProvider? = provider(held, capacity: 1)
    let weakProvider = WeakProviderReference(ending)
    let snapshot = try await value { [subject = ending!] in try await subject.prepare(.searchTrending(limit: 10)) }
    held.immediate = nil
    let finisher = Task { [subject = ending!] in try await subject.finish(snapshot, response: response(snapshot)) }
    try await until("ending capacity") { held.terminalCalls.count == 1 }
    try await error({ [subject = ending!] in _ = try await subject.prepare(.searchTrending(limit: 10)) },
      { ($0 as? PiliHTTPRequestContextError) == .capacity }, "Ending contexts count toward capacity")
    ending!.dispose()
    try expect(ending!.activeContextCount == 0 && held.terminalCalls.count == 1, "Dispose never replaces an already dispatched finish")
    held.complete(1, .success(receipt()))
    _ = try await value { try await finisher.value }
    ending = nil; held.dropReplies()
    try await until("released provider") { weakProvider.value == nil }
    try expect(weakProvider.value == nil && held.terminalCalls.count == 1, "Independent terminal task releases provider after ack and callbacks drop")
  }
}
