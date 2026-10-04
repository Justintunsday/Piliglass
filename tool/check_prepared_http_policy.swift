import Foundation

private struct Failure: Error { let message: String }

@MainActor
private final class GoldenTransport: PiliBridgeMethodTransport {
  let prepared: PiliBridgeValue
  var terminalMethods: [String] = []
  init(_ prepared: PiliBridgeValue) { self.prepared = prepared }
  func invoke(_ method: String, arguments: [String: PiliBridgeValue]?,
              completion: @escaping @Sendable (Result<PiliBridgeValue, PiliBridgeInvocationError>) -> Void) {
    if method == "prepareNativeHTTPRequest", case .dictionary(var fields) = prepared {
      fields["requestID"] = arguments?["requestID"]
      completion(.success(.dictionary(fields)))
    } else {
      terminalMethods.append(method)
      completion(.success(.dictionary(["state": .string("abandoned"), "cookiesSaved": .bool(false),
        "cookieCount": .integer(0), "executionAllowed": .bool(false)])))
    }
  }
}

@main @MainActor
private struct PreparedHTTPPolicyChecks {
  static var checks = 0
  static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure(message: message) }; checks += 1
  }
  static func decode(_ value: PiliBridgeValue) throws -> PiliHTTPRequestContext {
    guard case .dictionary(let fields) = value, case .string(let id) = fields["requestID"] else {
      throw Failure(message: "Missing real Dart request ID")
    }
    return try PiliHTTPRequestContextBridgeCodec.decodePrepared(value, requestID: id, purpose: .searchTrending(limit: 10))
  }
  static func main() async {
    do {
      for path in CommandLine.arguments.dropFirst() {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let report = raw as? [String: Any], let h2 = report["http2"] as? Bool,
              let cases = report["cases"] as? [[String: Any]], cases.count == 8,
              report["source"] as? String == "actual Dart bridge + Hive + installed Request pool" else {
          throw Failure(message: "Actual Dart bridge golden report required")
        }
        for fixture in cases {
          guard let name = fixture["id"] as? String else { throw Failure(message: "Missing case") }
          let value = try PiliBridgeValue(codecValue: fixture["prepared"])
          let context = try decode(value), policy = context.policy
          try expect(!context.executionAllowed && !policy.followRedirects, "Endpoint override and closed runtime gate")
          try expect(policy.version == 1 && policy.connectTimeoutMicroseconds == 10_000_001 &&
            policy.receiveIdleTimeoutMicroseconds == 10_000_003 && policy.sendTimeoutMicroseconds == 9_000_007 &&
            policy.transformTimeoutMicroseconds == 8_000_009 && policy.receiveDataWhenStatusError,
            "Dart Duration microseconds survive the actual codec")
          let crossed = await Task.detached { context }.value
          try expect(crossed == context, "Full policy context is Sendable under Swift 6 complete")
          if name == "unknown-pool" {
            try expect(policy.pool == nil && policy.issues.contains(.adapterChanged) && !policy.isDescribed,
                       "Untracked actual adapter cannot borrow the known pool")
          } else {
            try expect(policy.pool?.http2Enabled == h2 && policy.poolGeneration > 0,
                       "Installed actual H1/H2 pool survives")
            try expect(policy.pool?.http2ALPN == (h2 ? ["h2"] : []) && policy.pool?.autoUncompress == false,
                       "Pinned ALPN and manual decompression description survives")
          }
          switch name {
          case "retry-two", "forced-http11":
            try expect(policy.retry?.installed == true && policy.retry?.count == 2 && policy.retry?.delayMilliseconds == 500,
                       "Actual copied/bound retry")
            try expect(policy.clientMode == (name == "forced-http11" ? .http11 : .main), "Selected client mode retained")
          case "retry-installed-zero":
            try expect(policy.retry?.installed == true && policy.retry?.count == 0 && policy.retry?.delayMilliseconds == 37,
                       "Installed zero is distinct from absence")
          case "retry-absent":
            try expect(policy.retry?.installed == false && policy.retry?.count == 0 && policy.retry?.delayMilliseconds == nil,
                       "No interceptor does not invent a delay")
          case "retry-signed-unsupported":
            try expect(policy.retry?.count == -1 && policy.retry?.delayMilliseconds == -7,
                       "Unsupported signed values are described without granting capability")
          case "proxy-signed-unsupported":
            try expect(policy.pool?.proxy?.port == -1 && policy.pool?.http11AcceptsBadCertificate == true,
                       "Configured proxy and trust are not silently normalized")
          case "unknown-decoder":
            try expect(policy.decoder == .unknown && policy.issues == [.decoderChanged] && !policy.isDescribed,
                       "Untracked decoder remains explicitly unknown")
          case "unknown-pool": break
          default: throw Failure(message: "Unexpected golden case")
          }
          let transport = GoldenTransport(value)
          let provider = PiliFlutterHTTPRequestContextProvider(transport: transport)
          let prepared = try await provider.prepare(.searchTrending(limit: 10))
          try expect(prepared.policy == policy, "Production invoker/provider consumes the actual Dart policy")
          _ = try await provider.abandon(prepared)
          try expect(transport.terminalMethods == ["abandonNativeHTTPRequest"] && provider.activeContextCount == 0,
                     "Actual golden terminates once")
          provider.dispose()
          if name == "retry-two" { try await malformedChecks(value) }
        }
      }
      try expect(CommandLine.arguments.count == 3, "Both cold-boot H1 and H2 golden files required")
      print("\(checks) prepared HTTP policy checks passed (actual Dart bridge/Hive goldens + Swift 6 production provider)")
    } catch { print("FAIL prepared HTTP policy checks: \(error)"); exit(1) }
  }

  static func malformedChecks(_ good: PiliBridgeValue) async throws {
    guard case .dictionary(let fields) = good, case .dictionary(let policy) = fields["policy"],
          case .dictionary(let pool) = policy["pool"], case .dictionary(let retry) = policy["retry"] else {
      throw Failure(message: "Known golden structure expected")
    }
    var malformed: [PiliBridgeValue] = [.null, .bool(false), .dictionary([:])]
    for key in policy.keys { var copy = policy; copy.removeValue(forKey: key); malformed.append(.dictionary(copy)) }
    let badFields: [(String, PiliBridgeValue)] = [
      ("version", .integer(2)), ("version", .bool(true)), ("version", .double(1)),
      ("poolGeneration", .integer(-1)), ("poolGeneration", .integer(0)), ("clientMode", .string("auto")),
      ("connectTimeoutMicroseconds", .double(10_000_001)), ("sendTimeoutMicroseconds", .bool(false)),
      ("receiveIdleTimeoutMicroseconds", .integer(-1)), ("persistentConnection", .integer(1)),
      ("followRedirects", .bool(true)), ("maxRedirects", .double(5)), ("acceptEncoding", .string("mismatch")),
      ("responseType", .string("invented")), ("decoder", .string("unknown")),
      ("pool", .null), ("retry", .null), ("issues", .array([.string("unknownIssue")])),
      ("issues", .array([.string("decoderChanged"), .string("decoderChanged")]))]
    for (key, value) in badFields { var copy = policy; copy[key] = value; malformed.append(.dictionary(copy)) }
    for key in pool.keys {
      var copy = pool; copy.removeValue(forKey: key)
      var outer = policy; outer["pool"] = .dictionary(copy); malformed.append(.dictionary(outer))
    }
    for (key, value) in [("http2Enabled", PiliBridgeValue.integer(1)),
                         ("autoUncompress", .bool(true)), ("http2ALPN", .array([.string("http/1.1")])),
                         ("http11AcceptsBadCertificate", .bool(true))] {
      var copy = pool; copy[key] = value
      var outer = policy; outer["pool"] = .dictionary(copy); malformed.append(.dictionary(outer))
    }
    for key in retry.keys {
      var copy = retry; copy.removeValue(forKey: key)
      var outer = policy; outer["retry"] = .dictionary(copy); malformed.append(.dictionary(outer))
    }
    for (key, value) in [("installed", PiliBridgeValue.integer(1)), ("count", .bool(true)),
                         ("delayMilliseconds", .double(500)), ("installed", .bool(false))] {
      var copy = retry; copy[key] = value
      var outer = policy; outer["retry"] = .dictionary(copy); malformed.append(.dictionary(outer))
    }
    var extra = policy; extra["unexpected"] = .bool(false); malformed.append(.dictionary(extra))
    for invalid in malformed {
      var copy = fields; copy["policy"] = invalid
      let payload = PiliBridgeValue.dictionary(copy)
      do { _ = try decode(payload); throw Failure(message: "Malformed policy accepted") }
      catch PiliHTTPRequestContextError.invalidResponse { checks += 1 }
      let transport = GoldenTransport(payload)
      let provider = PiliFlutterHTTPRequestContextProvider(transport: transport, terminalTimeoutNanoseconds: 100_000_000)
      do { _ = try await provider.prepare(.searchTrending(limit: 10)); throw Failure(message: "Provider accepted malformed policy") }
      catch PiliHTTPRequestContextError.invalidResponse { checks += 1 }
      for _ in 0..<200 {
        if provider.activeContextCount == 0 { break }
        await Task.yield(); try await Task.sleep(nanoseconds: 1_000_000)
      }
      try expect(provider.activeContextCount == 0 && transport.terminalMethods == ["abandonNativeHTTPRequest"],
                 "Malformed nested policy is cleaned once without retry")
      provider.dispose()
    }
  }
}
