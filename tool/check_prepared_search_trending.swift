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
  var usesDart: Bool { name == "declined" || name == "redirects" }

  init(_ raw: [String: Any]) throws {
    guard let name = raw["name"] as? String,
          let terminalMethod = raw["terminalMethod"] as? String,
          let encoded = raw["body"] as? String, let body = Data(base64Encoded: encoded),
          let keywords = raw["keywords"] as? [[String: String]] else {
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
  private var requestID: PiliBridgeValue?
  private(set) var methods: [String] = []
  private(set) var mismatch: String?

  init(_ fixture: TrendingFixture) { self.fixture = fixture }

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
      guard arguments == ["includeTrending": .bool(false)] else { return nil }
      return .dictionary([
        "state": .string("success"), "trendingEnabled": .bool(true),
        "history": .array([.string("saved")]),
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
  let head: PiliHTTPResponseHead?
  let body: Data
  let cookie: String
  private(set) var sends = 0
  private(set) var matchedRequest = false

  init(_ fixture: TrendingFixture) throws {
    guard case .dictionary(let headers) = fixture.prepared["headers"],
          case .string(let cookie) = headers["cookie"] else { throw FixtureError(message: "Missing Dart Cookie") }
    self.cookie = cookie
    body = fixture.body
    if case .dictionary(let response) = fixture.terminal["response"],
       case .string(let rawURL) = response["url"], let url = URL(string: rawURL),
       case .integer(let status) = response["statusCode"], let statusCode = Int(exactly: status),
       case .array(let fields) = response["setCookieValues"] {
      let cookieFields = try fields.map { raw in
        guard case .string(let field) = raw else { throw FixtureError(message: "Invalid Dart Set-Cookie field") }
        return field
      }
      head = PiliHTTPResponseHead(url: url, statusCode: statusCode, headers: ["content-encoding": "gzip"],
                                  cookieFields: .separatedFields(cookieFields))
    } else if fixture.usesDart {
      head = nil
    } else {
      throw FixtureError(message: "Missing Dart response head")
    }
  }

  func transfer(
    _ request: URLRequest,
    onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void
  ) async -> PiliHTTPTransferOutcome {
    sends += 1
    guard let head, request.url == head.url, request.httpMethod == "GET",
          !request.httpShouldHandleCookies, request.value(forHTTPHeaderField: "Cookie") == cookie else {
      return .init(head: nil, body: .failure(.client(.invalidRequest)))
    }
    matchedRequest = true
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
      let expected: Set<String> = ["selected", "switched", "revoked", "httpError", "corrupt", "declined", "redirects"]
      guard fixtures.count == expected.count, Set(fixtures.map(\.name)) == expected else {
        throw FixtureError(message: "Missing or repeated Dart trending scenarios")
      }
      for fixture in fixtures { try await check(fixture) }
      print("\(fixtures.count) actual Dart prepared trending cases passed")
    } catch {
      print("FAIL prepared trending: \(error)")
      exit(1)
    }
  }

  static func check(_ fixture: TrendingFixture) async throws {
    if fixture.name == "declined" { try await checkRawCandidate(fixture) }
    let bridge = FixtureBridge(fixture)
    let transfer = try FixtureTransfer(fixture)
    let declined = fixture.usesDart
    let loader = PiliPreparedSearchTrendingLoader(bridge: bridge, transport: transfer,
      evidence: fixture.name == "declined" ? .rawCandidate : .syntheticComplete, maximumBodyBytes: 65_536)
    var failure: Error?
    let repository = PiliFlutterSearchRepository(invoker: PiliBridgeMethodInvoker(transport: bridge)) {
      do { return try await loader.load() }
      catch { failure = error; throw error }
    }
    let result = try await repository.discovery()
    let methods = ["loadNativeSearchDiscovery", "prepareNativeHTTPRequest", fixture.terminalMethod]
    let suffix: [String]
    switch fixture.name {
    case "declined", "redirects": suffix = ["loadNativeSearchTrending"]
    case "selected", "switched": suffix = ["loadNativeAccountSelection"]
    default: suffix = []
    }
    let sends = await transfer.sends
    let matched = await transfer.matchedRequest
    guard bridge.mismatch == nil, bridge.methods == methods + suffix,
          sends == (declined ? 0 : 1), matched == !declined,
          result.history == ["saved"], result.recommendations.map(\.keyword) == ["pick"] else {
      throw FixtureError(message: "\(fixture.name): altered bridge command, transfer, or discovery state")
    }
    let valid: Bool
    switch fixture.name {
    case "selected":
      valid = failure == nil && !fixture.keywords.isEmpty && result.trending == fixture.keywords
    case "switched":
      valid = failure == nil && result.trending.isEmpty
    case "revoked":
      valid = (failure as? PiliPreparedHTTPRequestExecutionError) == .terminalNotConfirmed(.revoked)
        && result.trending.isEmpty
    case "httpError":
      valid = (failure as? PiliSearchTrendingError) == .httpStatus(403) && result.trending.isEmpty
    case "corrupt":
      valid = (failure as? PiliHTTPBodyDecodeFailure) == .malformedCompression && result.trending.isEmpty
    case "declined", "redirects":
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

  static func checkRawCandidate(_ fixture: TrendingFixture) async throws {
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
          profile.poolIdleMicroseconds == 15_000_000 else {
      throw FixtureError(message: "Raw configuration drifted from the actual Dart pool")
    }
    let client = try PiliRawHTTPClient(profile: profile, maximumBodyBytes: 65_536)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:1/trending-fixture")!)
    request.httpMethod = "GET"
    let rejected = await client.transfer(request, onHead: { _ in })
    try await client.shutdown()
    guard rejected.head == nil,
          case .failure(.client(.nativeTransport(kind: "invalidRequest"))) = rejected.body else {
      throw FixtureError(message: "The configured candidate accepted a plain HTTP fixture URL")
    }
  }
}
