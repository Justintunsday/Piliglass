import Foundation
import PiliHTTPBodyCodec

private struct FixtureError: Error { let message: String }

private struct TrendingFixture {
  let name: String
  let prepare: [String: PiliBridgeValue]
  let prepared: [String: PiliBridgeValue]
  let terminalMethod: String
  let terminal: [String: PiliBridgeValue]
  let receipt: PiliBridgeValue
  let selection: PiliBridgeValue
  let body: Data
  let keywords: [PiliSearchKeyword]
  let retries: [(command: [String: PiliBridgeValue], reply: [String: PiliBridgeValue])]
  let reissues: [(command: [String: PiliBridgeValue], reply: [String: PiliBridgeValue])]
  let intermediate: [(head: [String: PiliBridgeValue], body: Data)]
  let decodingFailures: [(encoding: String?, body: Data)]
  var usesDart: Bool { name == "declined" || name == "redirects" || name == "unsupportedTrial" }
  var authorizedRetryCookies: [String] {
    retries.compactMap { retry in
      guard case .dictionary(let headers) = retry.reply["headers"],
            case .string(let cookie) = headers["cookie"] else { return nil }
      return cookie
    }
  }
  var authorizedReissues: [[String: PiliBridgeValue]] {
    reissues.compactMap { $0.reply["state"] == .string("redirectPrepared") ? $0.reply : nil }
  }

  init(_ raw: [String: Any]) throws {
    guard let name = raw["name"] as? String,
          let terminalMethod = raw["terminalMethod"] as? String,
          let encoded = raw["body"] as? String, let body = Data(base64Encoded: encoded),
          let keywords = raw["keywords"] as? [[String: String]], let retries = raw["retries"] as? [[String: Any]],
          let reissues = (raw["reissues"] ?? []) as? [[String: Any]],
          let intermediate = (raw["intermediate"] ?? []) as? [[String: Any]],
          let decodingFailures = (raw["decodingFailures"] ?? []) as? [[String: Any]] else {
      throw FixtureError(message: "Invalid Dart trending fixture")
    }
    self.name = name
    prepare = try Self.fields(raw["prepare"])
    prepared = try Self.fields(raw["prepared"])
    self.terminalMethod = terminalMethod
    terminal = try Self.fields(raw["terminal"])
    receipt = try PiliBridgeValue(codecValue: raw["receipt"])
    selection = try PiliBridgeValue(codecValue: raw["selection"])
    self.body = body
    self.retries = try retries.map { entry in
      (command: try Self.fields(entry["command"]), reply: try Self.fields(entry["reply"]))
    }
    self.reissues = try reissues.map { entry in
      (command: try Self.fields(entry["command"]), reply: try Self.fields(entry["reply"]))
    }
    self.intermediate = try intermediate.map { entry in
      guard let rawBody = entry["body"] as? String, let bytes = Data(base64Encoded: rawBody) else {
        throw FixtureError(message: "Missing interceptor response body")
      }
      return (head: try Self.fields(entry["head"]), body: bytes)
    }
    self.decodingFailures = try decodingFailures.map { entry in
      guard let rawBody = entry["body"] as? String, let body = Data(base64Encoded: rawBody) else {
        throw FixtureError(message: "Missing invalid response body")
      }
      return (entry["encoding"] as? String, body)
    }
    self.keywords = try keywords.map { fields in
      guard let keyword = fields["keyword"], let reason = fields["reason"] else {
        throw FixtureError(message: "Invalid expected Dart keyword")
      }
      return PiliSearchKeyword(keyword: keyword, reason: reason, icon: fields["icon"])
    }
  }

  private static func fields(_ value: Any?) throws -> [String: PiliBridgeValue] {
    guard case .dictionary(let fields) = try PiliBridgeValue(codecValue: value) else {
      throw FixtureError(message: "Missing prepared or terminal bridge fields")
    }
    return fields
  }
}

@MainActor
private final class FixtureBridge: PiliBridgeMethodTransport {
  let fixture: TrendingFixture
  let aggregatedDiscovery: Bool
  private var requestID: PiliBridgeValue?
  private var retryIndex = 0
  private var redirectIndex = 0
  private(set) var methods: [String] = []
  private(set) var mismatch: String?

  init(_ fixture: TrendingFixture, aggregatedDiscovery: Bool = false) {
    self.fixture = fixture
    self.aggregatedDiscovery = aggregatedDiscovery
  }

  func invoke(
    _ method: String,
    arguments: [String: PiliBridgeValue]?,
    completion: @escaping @Sendable (Result<PiliBridgeValue, PiliBridgeInvocationError>) -> Void
  ) {
    methods.append(method)
    if let response = reply(method, arguments: arguments) {
      completion(.success(response))
    } else {
      mismatch = method
      completion(.failure(.invalidValue))
    }
  }

  private func reply(_ method: String, arguments: [String: PiliBridgeValue]?) -> PiliBridgeValue? {
    switch method {
    case "loadNativeSearchDiscovery":
      guard arguments == (aggregatedDiscovery ? nil : ["includeTrending": .bool(false)]) else { return nil }
      return .dictionary([
        "state": .string("success"), "trendingEnabled": .bool(true),
        "history": .array([.string("saved")]),
        "trending": .array([.dictionary(["keyword": .string("Dart aggregate")])]),
        "recommendations": .array([.dictionary(["keyword": .string("pick")])])
      ])
    case "prepareNativeHTTPRequest":
      guard requestID == nil, case .string(let id) = arguments?["requestID"],
            UUID(uuidString: id) != nil else { return nil }
      var expected = fixture.prepare
      expected["requestID"] = .string(id)
      guard arguments == expected else { return nil }
      requestID = .string(id)
      var prepared = fixture.prepared
      prepared["requestID"] = requestID
      return .dictionary(prepared)
    case "prepareNativeHTTPRetry":
      guard let requestID, retryIndex < fixture.retries.count else { return nil }
      let retry = fixture.retries[retryIndex]
      var expected = retry.command
      expected["requestID"] = requestID
      guard arguments == expected else { return nil }
      retryIndex += 1
      var reply = retry.reply
      if reply["requestID"] != nil { reply["requestID"] = requestID }
      return .dictionary(reply)
    case "prepareNativeHTTPRedirect":
      guard let requestID, redirectIndex < fixture.reissues.count else { return nil }
      let reissue = fixture.reissues[redirectIndex]
      var expected = reissue.command
      expected["requestID"] = requestID
      guard arguments == expected else { return nil }
      redirectIndex += 1
      var reply = reissue.reply
      if reply["requestID"] != nil { reply["requestID"] = requestID }
      return .dictionary(reply)
    case fixture.terminalMethod:
      var expected = fixture.terminal
      expected["requestID"] = requestID
      guard requestID != nil, arguments == expected else { return nil }
      return fixture.receipt
    case "loadNativeAccountSelection":
      return arguments == nil ? fixture.selection : nil
    case "loadNativeSearchTrending":
      guard arguments == nil else { return nil }
      return .dictionary([
        "state": .string("success"), "items": .array([.dictionary(["keyword": .string("Dart hot")])])
      ])
    default:
      return nil
    }
  }
}

private actor FixtureTransfer: PiliHTTPTransferring {
  private struct RequestStep {
    let url: URL
    let cookie: String
    let redirectLimit: Int?
  }
  let head: PiliHTTPResponseHead?
  let body: Data
  private let requests: [RequestStep]
  private let intermediate: [(PiliHTTPResponseHead, Data)]
  let retryableFailures: [String]
  let truncatedResponses: Int
  let decodingFailures: [(encoding: String?, body: Data)]
  private(set) var sends = 0
  private(set) var matchedRequest = false

  init(_ fixture: TrendingFixture) throws {
    guard case .dictionary(let headers) = fixture.prepared["headers"],
          case .string(let cookie) = headers["cookie"], case .string(let request) = fixture.prepared["url"],
          let requestedURL = URL(string: request), case .dictionary(let policy) = fixture.prepared["policy"],
          case .integer(let maximum) = policy["maxRedirects"], let maximumRedirects = Int(exactly: maximum) else {
      throw FixtureError(message: "Missing Dart request")
    }
    let limit: Int? = policy["followRedirects"] == .bool(true) ? maximumRedirects : nil
    requests = ([cookie] + fixture.authorizedRetryCookies).map {
      RequestStep(url: requestedURL, cookie: $0, redirectLimit: limit)
    } + (try fixture.authorizedReissues.map { reply in
      guard case .string(let target) = reply["url"], let url = URL(string: target),
            case .dictionary(let headers) = reply["headers"], case .string(let cookie) = headers["cookie"],
            case .integer(let remaining) = reply["remainingRedirects"], let limit = Int(exactly: remaining) else {
        throw FixtureError(message: "Missing prepared reissue request")
      }
      return RequestStep(url: url, cookie: cookie, redirectLimit: limit)
    })
    retryableFailures = switch fixture.name {
    case "retried": ["connectionRefused", "remoteConnectionClosed"]
    case "retryRevoked": ["remoteConnectionClosed"]
    default: []
    }
    let truncatedResponses = switch fixture.name {
    case "bodyRetried": fixture.retries.count
    case "bodyRetryExhausted": fixture.retries.count + 1
    case "decodeRetryExhausted": 1
    default: 0
    }
    self.truncatedResponses = truncatedResponses
    decodingFailures = fixture.decodingFailures
    body = fixture.body
    let intermediate = try fixture.intermediate.map { frame in
      (try Self.responseHead(frame.head, headers: ["content-type": "application/json"]), frame.body)
    }
    self.intermediate = intermediate
    if case .dictionary(let response) = fixture.terminal["response"] {
      head = try Self.responseHead(response, headers: ["content-encoding": "gzip", "content-type": "application/json"],
        waitForBody: truncatedResponses > 0 || !fixture.decodingFailures.isEmpty || fixture.name == "apiRejected")
    } else if fixture.usesDart || fixture.name == "retryRevoked" || truncatedResponses > 0 || !intermediate.isEmpty {
      head = nil
    } else {
      throw FixtureError(message: "Missing Dart response head")
    }
  }

  private static func responseHead(_ response: [String: PiliBridgeValue], headers: [String: String],
                                   waitForBody: Bool = false) throws -> PiliHTTPResponseHead {
    guard case .string(let rawURL) = response["url"], let url = URL(string: rawURL),
          case .integer(let status) = response["statusCode"], let statusCode = Int(exactly: status),
          case .array(let fields) = response["setCookieValues"] else { throw FixtureError(message: "Missing Dart response head") }
    let cookieFields = try fields.map { raw in
      guard case .string(let field) = raw else { throw FixtureError(message: "Invalid Dart Set-Cookie field") }
      return field
    }
    let redirects = try Self.redirects(response["redirects"])
    let locations: [String]?
    if let rawLocations = response["locationValues"] {
      guard case .array(let values) = rawLocations else { throw FixtureError(message: "Expected Dart Location list") }
      locations = try values.map { raw in
        guard case .string(let field) = raw else { throw FixtureError(message: "Invalid Dart Location field") }
        return field
      }
    } else {
      locations = nil
    }
    return .init(url: url, statusCode: statusCode, headers: headers,
      cookieFields: .separatedFields(cookieFields), redirects: redirects, locationValues: locations,
      requiresCompleteBodyForWriteBack: waitForBody)
  }

  private static func redirects(_ value: PiliBridgeValue?) throws -> [PiliHTTPRedirectHop] {
    guard let value else { return [] }
    guard case .array(let hops) = value else { throw FixtureError(message: "Expected Dart redirect list") }
    return try hops.map { hop in
      guard case .dictionary(let fields) = hop, case .integer(let status) = fields["statusCode"],
            let statusCode = Int(exactly: status), case .string(let location) = fields["location"],
            case .string(let rawURL) = fields["url"], let url = URL(string: rawURL) else {
        throw FixtureError(message: "Missing Dart redirect fields")
      }
      return .init(statusCode: statusCode, location: location, url: url)
    }
  }

  func transfer(
    _ request: URLRequest,
    redirectLimit: Int?,
    onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void
  ) async -> PiliHTTPTransferOutcome {
    let index = sends
    sends += 1
    matchedRequest = (index == 0 || matchedRequest) && index < requests.count && request.url == requests[index].url
      && request.httpMethod == "GET" && !request.httpShouldHandleCookies
      && request.value(forHTTPHeaderField: "Cookie") == requests[index].cookie
      && redirectLimit == requests[index].redirectLimit
    guard matchedRequest else {
      return .init(head: nil, body: .failure(.client(.invalidRequest)))
    }
    if index < truncatedResponses {
      let head = PiliHTTPResponseHead(url: request.url!, statusCode: 200, headers: ["content-type": "application/json"],
        cookieFields: .separatedFields(["trending_fixture=truncated; Path=/"]), requiresCompleteBodyForWriteBack: true)
      onHead(head)
      return .init(head: head, body: .failure(.client(.nativeTransport(kind: "remoteConnectionClosed"))),
                   retryEvidence: .incompleteResponseBody)
    }
    let retryIndex = index - truncatedResponses
    if retryableFailures.indices.contains(retryIndex) {
      return .init(head: nil, body: .failure(.client(.nativeTransport(kind: retryableFailures[retryIndex]))),
                   retryEvidence: .beforeResponseHead)
    }
    let decodingIndex = retryIndex - retryableFailures.count
    if decodingFailures.indices.contains(decodingIndex) {
      let frame = decodingFailures[decodingIndex]
      var headers = ["content-type": "application/json"]
      headers["content-encoding"] = frame.encoding
      let head = PiliHTTPResponseHead(url: request.url!, statusCode: 200, headers: headers,
        cookieFields: .separatedFields(["trending_fixture=undecodable; Path=/"]), requiresCompleteBodyForWriteBack: true)
      onHead(head)
      return .init(head: head, body: .success(frame.body))
    }
    let responseIndex = decodingIndex - decodingFailures.count
    if intermediate.indices.contains(responseIndex) {
      let (head, body) = intermediate[responseIndex]
      onHead(head)
      return .init(head: head, body: .success(body))
    }
    guard let head else { return .init(head: nil, body: .failure(.client(.invalidResponse))) }
    onHead(head)
    return .init(head: head, body: .success(body))
  }
}

@main @MainActor
private struct PreparedSearchTrendingChecks {
  static func main() async {
    do {
      guard CommandLine.arguments.count == 2,
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf:
              URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any],
            raw["version"] as? Int == 1, let cases = raw["cases"] as? [[String: Any]] else {
        throw FixtureError(message: "Fresh Dart trending fixture required")
      }
      let fixtures = try cases.map(TrendingFixture.init)
      let expected: Set<String> = ["selected", "switched", "revoked", "httpError", "corrupt", "declined", "redirects",
                                   "redirected", "redirectedSwitched", "redirectedHTTPError", "retried", "retryRevoked",
                                   "bodyRetried", "bodyRetryExhausted", "decodeRetried", "decodeRetryExhausted",
                                   "apiRejected", "unsupportedTrial",
                                   "terminalRedirect", "redirectedTerminal", "interceptorSuccess", "interceptorDenied",
                                   "interceptorExhausted", "interceptorCorrupt", "interceptorRevoked"]
      guard fixtures.count == expected.count, Set(fixtures.map(\.name)) == expected else {
        throw FixtureError(message: "Missing or repeated Dart trending scenarios")
      }
      for fixture in fixtures { try await check(fixture) }
      try await checkTrialEntry(fixtures)
      print("\(fixtures.count) actual Dart prepared trending cases passed")
    } catch {
      print("FAIL prepared trending: \(error)")
      exit(1)
    }
  }

  static func check(_ fixture: TrendingFixture) async throws {
    let bridge = FixtureBridge(fixture)
    let transfer = try FixtureTransfer(fixture)
    let declined = fixture.usesDart
    let loader = PiliPreparedSearchTrendingLoader(bridge: bridge, selectTransport: { policy in
      switch PiliHTTPPolicyCapability().evaluate(policy, evidence: declined ? .rawCandidate : .syntheticComplete) {
      case .native: return .native(transfer)
      case .dart(let reasons): return .dart(reasons)
      }
    }, maximumBodyBytes: 65_536)
    var failure: Error?
    let repository = PiliFlutterSearchRepository(invoker: PiliBridgeMethodInvoker(transport: bridge)) {
      do { return try await loader.load() }
      catch { failure = error; throw error }
    }
    let result = try await repository.discovery()
    let methods = ["loadNativeSearchDiscovery", "prepareNativeHTTPRequest"]
      + Array(repeating: "prepareNativeHTTPRetry", count: fixture.retries.count)
      + Array(repeating: "prepareNativeHTTPRedirect", count: fixture.reissues.count) + [fixture.terminalMethod]
    let suffix: [String]
    switch fixture.name {
    case "declined", "redirects", "unsupportedTrial": suffix = ["loadNativeSearchTrending"]
    case "selected", "switched", "redirected", "redirectedSwitched", "retried", "bodyRetried",
         "decodeRetried", "interceptorSuccess":
      suffix = ["loadNativeAccountSelection"]
    default: suffix = []
    }
    let sends = await transfer.sends
    let matched = await transfer.matchedRequest
    guard bridge.mismatch == nil, bridge.methods == methods + suffix,
          sends == (declined ? 0 : 1 + fixture.authorizedRetryCookies.count + fixture.authorizedReissues.count),
          matched == !declined,
          result.history == ["saved"], result.recommendations.map(\.keyword) == ["pick"] else {
      throw FixtureError(message: "\(fixture.name): altered bridge command, transfer, or discovery state")
    }
    let valid: Bool
    switch fixture.name {
    case "selected", "redirected", "retried", "bodyRetried", "decodeRetried", "interceptorSuccess":
      valid = failure == nil && !fixture.keywords.isEmpty && result.trending == fixture.keywords
    case "switched", "redirectedSwitched":
      valid = failure == nil && result.trending.isEmpty
    case "revoked":
      valid = (failure as? PiliPreparedHTTPRequestExecutionError) == .terminalNotConfirmed(.revoked)
        && result.trending.isEmpty
    case "retryRevoked", "interceptorRevoked":
      valid = (failure as? PiliHTTPRequestContextError) == .serviceFailure(code: "revoked") && result.trending.isEmpty
    case "bodyRetryExhausted":
      valid = (failure as? PiliHTTPClientError) == .nativeTransport(kind: "remoteConnectionClosed") && result.trending.isEmpty
    case "httpError", "redirectedHTTPError", "interceptorDenied":
      valid = (failure as? PiliSearchTrendingError) == .httpStatus(403) && result.trending.isEmpty
    case "terminalRedirect", "redirectedTerminal":
      valid = (failure as? PiliSearchTrendingError) == .httpStatus(fixture.name == "terminalRedirect" ? 302 : 300)
        && result.trending.isEmpty
    case "corrupt", "decodeRetryExhausted":
      valid = (failure as? PiliHTTPBodyDecodeFailure) == .malformedCompression && result.trending.isEmpty
    case "apiRejected":
      valid = (failure as? PiliSearchTrendingError) == .api(code: -400, message: "fixture denial")
        && result.trending.isEmpty
    case "interceptorCorrupt":
      valid = failure != nil && result.trending.isEmpty
    case "interceptorExhausted":
      valid = (failure as? PiliSearchTrendingError) == .httpStatus(300) && result.trending.isEmpty
    case "declined", "redirects", "unsupportedTrial":
      valid = failure == nil && result.trending.map(\.keyword) == ["Dart hot"]
    default:
      valid = false
    }
    guard valid else {
      let errorType = failure.map { String(describing: type(of: $0)) } ?? "none"
      throw FixtureError(message: "\(fixture.name): unexpected result (error type: \(errorType))")
    }
    print("PASS prepared trending \(fixture.name)")
  }

  static func checkTrialEntry(_ fixtures: [TrendingFixture]) async throws {
    guard let fixture = fixtures.first(where: { $0.name == "decodeRetried" }),
          let unsupported = fixtures.first(where: { $0.name == "unsupportedTrial" }),
          let unavailable = fixtures.first(where: { $0.name == "declined" }) else {
      throw FixtureError(message: "Missing Runner trial fixtures")
    }
    let transfer = try FixtureTransfer(fixture)
    let factory: PiliPreparedSearchTrendingLoader.MakeRawTransport = { profile in
      guard profile.redirectLimit == 5, profile.connectMicroseconds == 10_000_000,
            profile.receiveIdleMicroseconds == 10_000_000, profile.poolIdleMicroseconds == 15_000_000 else {
        throw FixtureError(message: "Unexpected Runner raw profile")
      }
      return transfer
    }
    let off = FixtureBridge(fixture, aggregatedDiscovery: true)
    let defaultRepository = PiliPreparedSearchTrendingLoader.repository(bridge: off, launchArguments: [],
                                                                      makeRawTransport: factory)
    let defaults = try await defaultRepository.discovery()
    guard off.mismatch == nil, off.methods == ["loadNativeSearchDiscovery"],
          defaults.trending.map(\.keyword) == ["Dart aggregate"], await transfer.sends == 0 else {
      throw FixtureError(message: "Runner without the launch argument changed the default Dart path")
    }

    let arguments = ["--pili-native-search-trending"]
    let on = FixtureBridge(fixture)
    let trial = PiliPreparedSearchTrendingLoader.repository(bridge: on, launchArguments: arguments,
                                                            makeRawTransport: factory)
    let native = try await trial.discovery()
    guard on.mismatch == nil, on.methods == ["loadNativeSearchDiscovery", "prepareNativeHTTPRequest",
      "prepareNativeHTTPRetry", "prepareNativeHTTPRetry", "finishNativeHTTPRequest", "loadNativeAccountSelection"],
      native.trending == fixture.keywords, await transfer.sends == 3, await transfer.matchedRequest else {
      throw FixtureError(message: "Runner trial did not take the prepared Native path for default HTTP/1.1")
    }

    for rejected in [unsupported, unavailable] {
      let bridge = FixtureBridge(rejected)
      let policyUnsupported = rejected.name == "unsupportedTrial"
      let repository = PiliPreparedSearchTrendingLoader.repository(bridge: bridge, launchArguments: arguments,
        makeRawTransport: { _ in
          if policyUnsupported { return transfer }
          throw PiliHTTPClientError.invalidRequest
        })
      let fallback = try await repository.discovery()
      guard bridge.mismatch == nil, bridge.methods == ["loadNativeSearchDiscovery", "prepareNativeHTTPRequest",
        "abandonNativeHTTPRequest", "loadNativeSearchTrending"],
        fallback.trending.map(\.keyword) == ["Dart hot"], await transfer.sends == 3 else {
        throw FixtureError(message: "\(rejected.name): Runner trial failed to fall back before sending")
      }
    }
    try await checkRawPool(fixture)
    print("PASS Runner trending default, opt-in recovery, pre-send fallback and pool reuse")
  }

  static func checkRawPool(_ fixture: TrendingFixture) async throws {
    guard case .string(let id) = fixture.prepared["requestID"] else {
      throw FixtureError(message: "Missing Dart ID for raw preflight")
    }
    let context = try PiliHTTPRequestContextBridgeCodec.decodePrepared(.dictionary(fixture.prepared),
      requestID: id, purpose: .searchTrending(limit: 10))
    guard case .candidate(let profile) = PiliHTTPPolicyCapability().planRawHTTP11(context.policy) else {
      throw FixtureError(message: "The direct HTTP/1.1 fixture should describe a representable configuration")
    }
    guard profile.poolGeneration == context.policy.poolGeneration,
          profile.connectMicroseconds == 10_000_000, profile.receiveIdleMicroseconds == 10_000_000,
          profile.poolIdleMicroseconds == 15_000_000,
          profile.redirectLimit == (context.policy.followRedirects ? Int(context.policy.maxRedirects) : nil) else {
      throw FixtureError(message: "Raw configuration drifted from the actual Dart pool")
    }
    let pool = PiliRawHTTPClientPool(maximumBodyBytes: 65_536)
    let client = try await pool.client(for: profile)
    let reused = try await pool.client(for: profile)
    let next = PiliRawHTTP11Profile(poolGeneration: profile.poolGeneration + 1,
      connectMicroseconds: profile.connectMicroseconds, receiveIdleMicroseconds: profile.receiveIdleMicroseconds,
      poolIdleMicroseconds: profile.poolIdleMicroseconds, redirectLimit: profile.redirectLimit)
    let replacement = try await pool.client(for: next)
    let stale = try await pool.client(for: profile)
    let stillCurrent = try await pool.client(for: next)
    guard client === reused, client !== replacement, stale !== client, stale !== replacement,
          replacement === stillCurrent else {
      throw FixtureError(message: "Raw pool did not reuse and replace clients by effective policy")
    }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:1/trending-fixture")!)
    request.httpMethod = "GET"
    let rejected = await client.transfer(request, redirectLimit: profile.redirectLimit, onHead: { _ in })
    guard rejected.head == nil,
          case .failure(.client(.nativeTransport(kind: "invalidRequest"))) = rejected.body else {
      throw FixtureError(message: "The configured candidate accepted a plain HTTP fixture URL")
    }
  }
}
