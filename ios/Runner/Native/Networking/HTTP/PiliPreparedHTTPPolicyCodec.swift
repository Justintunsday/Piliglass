import Foundation

enum PiliPreparedHTTPPolicyCodec {
  enum Failure: Error { case invalidPolicy }

  static func decode(_ value: PiliBridgeValue) throws -> PiliPreparedHTTPPolicy {
    let fields = try dictionary(value, keys: ["version", "poolGeneration", "clientMode", "pool", "retry",
      "connectTimeoutMicroseconds", "receiveIdleTimeoutMicroseconds", "sendTimeoutMicroseconds",
      "transformTimeoutMicroseconds", "receiveDataWhenStatusError",
      "persistentConnection", "followRedirects", "maxRedirects", "acceptEncoding", "responseType", "decoder", "issues"])
    let version = try integer(fields["version"])
    let generation = try integer(fields["poolGeneration"])
    guard version == 1, generation >= 0,
          let mode = PiliPreparedHTTPPolicy.ClientMode(rawValue: try string(fields["clientMode"])),
          let decoder = PiliPreparedHTTPPolicy.Decoder(rawValue: try string(fields["decoder"])) else {
      throw Failure.invalidPolicy
    }
    let issueNames = try strings(fields["issues"])
    let issues = try issueNames.map { name -> PiliPreparedHTTPPolicy.Issue in
      guard let issue = PiliPreparedHTTPPolicy.Issue(rawValue: name) else { throw Failure.invalidPolicy }
      return issue
    }
    guard Set(issueNames).count == issueNames.count else { throw Failure.invalidPolicy }
    let pool = try decodePool(fields["pool"])
    let retry = try decodeRetry(fields["retry"])
    guard (pool == nil) == issues.contains(where: { $0.affectsPool }),
          pool == nil || generation > 0,
          (retry == nil) == issues.contains(.retryNotDescribed),
          (decoder == .unknown) == issues.contains(.decoderChanged) else { throw Failure.invalidPolicy }
    let responseType = try string(fields["responseType"])
    guard ["json", "stream", "plain", "bytes"].contains(responseType) else { throw Failure.invalidPolicy }
    return PiliPreparedHTTPPolicy(version: version, poolGeneration: generation, clientMode: mode, pool: pool, retry: retry,
      connectTimeoutMicroseconds: try duration(fields["connectTimeoutMicroseconds"]),
      receiveIdleTimeoutMicroseconds: try duration(fields["receiveIdleTimeoutMicroseconds"]),
      sendTimeoutMicroseconds: try duration(fields["sendTimeoutMicroseconds"]),
      transformTimeoutMicroseconds: try duration(fields["transformTimeoutMicroseconds"]),
      receiveDataWhenStatusError: try boolean(fields["receiveDataWhenStatusError"]),
      persistentConnection: try boolean(fields["persistentConnection"]),
      followRedirects: try boolean(fields["followRedirects"]), maxRedirects: try integer(fields["maxRedirects"]),
      acceptEncoding: try optionalString(fields["acceptEncoding"]), responseType: responseType, decoder: decoder, issues: issues)
  }

  private static func decodePool(_ value: PiliBridgeValue?) throws -> PiliPreparedHTTPPolicy.Pool? {
    if value == .null { return nil }
    guard let value else { throw Failure.invalidPolicy }
    let fields = try dictionary(value, keys: ["http2Enabled", "idleTimeoutMicroseconds", "http11AcceptsBadCertificate",
      "http2AcceptsBadCertificate", "proxy", "autoUncompress", "http2ALPN"])
    let h2 = try boolean(fields["http2Enabled"])
    let trust11 = try boolean(fields["http11AcceptsBadCertificate"])
    let trust2: Bool?
    if fields["http2AcceptsBadCertificate"] == .null { trust2 = nil }
    else { trust2 = try boolean(fields["http2AcceptsBadCertificate"]) }
    let proxy: PiliPreparedHTTPPolicy.Proxy?
    if fields["proxy"] == .null { proxy = nil }
    else {
      guard let value = fields["proxy"] else { throw Failure.invalidPolicy }
      let raw = try dictionary(value, keys: ["host", "port"])
      let host = try string(raw["host"])
      guard !host.isEmpty else { throw Failure.invalidPolicy }
      proxy = PiliPreparedHTTPPolicy.Proxy(host: host, port: try integer(raw["port"]))
    }
    let alpn = try strings(fields["http2ALPN"])
    let uncompress = try boolean(fields["autoUncompress"])
    guard (trust2 != nil) == h2, alpn == (h2 ? ["h2"] : []), !uncompress,
          trust11 == (proxy != nil), proxy == nil || !h2 || trust2 == true,
          let idle = try duration(fields["idleTimeoutMicroseconds"]) else { throw Failure.invalidPolicy }
    return PiliPreparedHTTPPolicy.Pool(http2Enabled: h2, idleTimeoutMicroseconds: idle,
      http11AcceptsBadCertificate: trust11, http2AcceptsBadCertificate: trust2, proxy: proxy,
      autoUncompress: uncompress, http2ALPN: alpn)
  }

  private static func decodeRetry(_ value: PiliBridgeValue?) throws -> PiliPreparedHTTPPolicy.Retry? {
    if value == .null { return nil }
    guard let value else { throw Failure.invalidPolicy }
    let fields = try dictionary(value, keys: ["installed", "count", "delayMilliseconds"])
    let installed = try boolean(fields["installed"])
    let count = try integer(fields["count"])
    let delay = try optionalInteger(fields["delayMilliseconds"])
    // Signed configured values are retained. Native capability rejects
    // unsupported semantics later; absence is distinct from installed count 0.
    guard installed == (delay != nil), installed || count == 0 else { throw Failure.invalidPolicy }
    return PiliPreparedHTTPPolicy.Retry(installed: installed, count: count, delayMilliseconds: delay)
  }

  private static func dictionary(_ value: PiliBridgeValue, keys: Set<String>) throws -> [String: PiliBridgeValue] {
    guard case .dictionary(let fields) = value, Set(fields.keys) == keys else { throw Failure.invalidPolicy }
    return fields
  }
  private static func integer(_ value: PiliBridgeValue?) throws -> Int64 {
    guard case .integer(let result) = value else { throw Failure.invalidPolicy }; return result
  }
  private static func optionalInteger(_ value: PiliBridgeValue?) throws -> Int64? {
    if value == .null { return nil }; return try integer(value)
  }
  private static func duration(_ value: PiliBridgeValue?) throws -> Int64? {
    let result = try optionalInteger(value)
    guard result == nil || result! >= 0 else { throw Failure.invalidPolicy }; return result
  }
  private static func boolean(_ value: PiliBridgeValue?) throws -> Bool {
    guard case .bool(let result) = value else { throw Failure.invalidPolicy }; return result
  }
  private static func string(_ value: PiliBridgeValue?) throws -> String {
    guard case .string(let result) = value else { throw Failure.invalidPolicy }; return result
  }
  private static func optionalString(_ value: PiliBridgeValue?) throws -> String? {
    if value == .null { return nil }; return try string(value)
  }
  private static func strings(_ value: PiliBridgeValue?) throws -> [String] {
    guard case .array(let values) = value else { throw Failure.invalidPolicy }
    return try values.map { try string($0) }
  }
}
