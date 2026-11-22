import Foundation

/// Strictness applies to the owned String-key snapshot from PiliBridgeValue.
/// The existing transport copier's non-String-key compatibility is unchanged.
enum PiliHTTPRequestContextBridgeCodec {
  static func prepareArguments(
    requestID: String,
    purpose: PiliHTTPRequestPurpose
  ) throws -> [String: PiliBridgeValue] {
    guard let requestID = canonicalID(requestID), (1...30).contains(purpose.limit) else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    return ["requestID": .string(requestID), "purpose": .string("searchTrending"),
            "limit": .integer(Int64(purpose.limit))]
  }

  static func decodePrepared(
    _ value: PiliBridgeValue,
    requestID: String,
    purpose: PiliHTTPRequestPurpose
  ) throws -> PiliHTTPRequestContext {
    let fields = try response(value)
    guard Set(fields.keys) == Set(["state", "requestID", "leaseID", "url", "method", "headers",
                                  "revision", "generation", "limit", "policy", "executionAllowed"]),
          fields["state"] == .string("prepared"),
          case .string(let returnedID) = fields["requestID"],
          let expectedID = canonicalID(requestID), canonicalID(returnedID) == expectedID,
          case .string(let leaseID) = fields["leaseID"], canonicalID(leaseID) != nil,
          case .string(let urlString) = fields["url"],
          let expectedURL = url(for: purpose), urlString == expectedURL.absoluteString,
          fields["method"] == .string("GET"),
          case .integer(let revision) = fields["revision"], revision >= 0,
          case .integer(let generation) = fields["generation"], generation > 0,
          fields["limit"] == .integer(Int64(purpose.limit)),
          case .dictionary(let rawHeaders) = fields["headers"] else {
      throw PiliHTTPRequestContextError.invalidResponse
    }
    let validatedHeaders = try headers(rawHeaders)
    let policy: PiliPreparedHTTPPolicy
    do {
      guard let rawPolicy = fields["policy"] else { throw PiliHTTPRequestContextError.invalidResponse }
      policy = try PiliPreparedHTTPPolicyCodec.decode(rawPolicy)
    } catch { throw PiliHTTPRequestContextError.invalidResponse }
    guard policy.acceptEncoding == validatedHeaders.first(where: { $0.key.lowercased() == "accept-encoding" })?.value else {
      throw PiliHTTPRequestContextError.invalidResponse
    }
    return PiliHTTPRequestContext(requestID: expectedID, leaseID: leaseID,
      request: PiliHTTPRequestDescriptor(url: expectedURL, method: "GET", headers: validatedHeaders),
      revision: revision, generation: generation, limit: purpose.limit, policy: policy)
  }

  static func retryArguments(context: PiliHTTPRequestContext, attempt: Int64) throws -> [String: PiliBridgeValue] {
    guard let requestID = canonicalID(context.requestID), let leaseID = canonicalID(context.leaseID),
          let retry = context.policy.retry, retry.installed, attempt > 0, attempt <= retry.count else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    return ["requestID": .string(requestID), "leaseID": .string(leaseID), "attempt": .integer(attempt)]
  }

  static func decodeRetry(_ value: PiliBridgeValue, context: PiliHTTPRequestContext, attempt: Int64) throws -> [String: String] {
    let fields = try response(value)
    guard Set(fields.keys) == Set(["state", "requestID", "leaseID", "attempt", "headers", "executionAllowed"]),
          fields["state"] == .string("retryPrepared"), fields["attempt"] == .integer(attempt),
          let requestID = canonicalID(context.requestID), fields["requestID"] == .string(requestID),
          let leaseID = canonicalID(context.leaseID), fields["leaseID"] == .string(leaseID),
          case .dictionary(let rawHeaders) = fields["headers"] else {
      throw PiliHTTPRequestContextError.invalidResponse
    }
    let refreshed = try headers(rawHeaders)
    func isCookie(_ name: String) -> Bool { name.lowercased() == "cookie" }
    guard refreshed.keys.contains(where: isCookie),
          refreshed.filter({ !isCookie($0.key) }) == context.request.headers.filter({ !isCookie($0.key) }) else {
      throw PiliHTTPRequestContextError.invalidResponse
    }
    return refreshed
  }

  static func finishArguments(
    context: PiliHTTPRequestContext,
    response: PiliHTTPRequestResponseCookies
  ) throws -> [String: PiliBridgeValue] {
    guard let requestID = canonicalID(context.requestID), canonicalID(context.leaseID) != nil,
          let expectedURL = url(for: .searchTrending(limit: context.limit)),
          context.request.url.absoluteString == expectedURL.absoluteString,
          context.request.method == "GET",
          (100...599).contains(response.statusCode) else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    let redirects = try redirectArguments(response, original: expectedURL, policy: context.policy)
    let locations = try terminalLocationArguments(response, original: expectedURL, policy: context.policy)
    var fields: [String: PiliBridgeValue] = ["url": .string(response.url.absoluteString),
      "statusCode": .integer(Int64(response.statusCode)), "cookieSource": .string(response.cookieSource.rawValue),
      "setCookieValues": .array(response.setCookieValues.map(PiliBridgeValue.string))]
    if !redirects.isEmpty { fields["redirects"] = .array(redirects) }
    if let locations { fields["locationValues"] = .array(locations) }
    return ["requestID": .string(requestID), "leaseID": .string(context.leaseID), "response": .dictionary(fields)]
  }

  private static func redirectArguments(
    _ response: PiliHTTPRequestResponseCookies, original: URL, policy: PiliPreparedHTTPPolicy
  ) throws -> [PiliBridgeValue] {
    guard let last = response.redirects.last else {
      guard response.url.absoluteString == original.absoluteString else {
        throw PiliHTTPRequestContextError.invalidRequest
      }
      return []
    }
    guard policy.followRedirects, Int64(response.redirects.count) <= policy.maxRedirects,
          response.cookieSource == .separatedFields, response.statusCode >= 200 else {
      throw PiliHTTPRequestContextError.invalidRequest
    }

    var current = original
    var visited = Set<String>()
    let encoded: [PiliBridgeValue] = try response.redirects.map { hop in
      guard autoRedirectStatuses.contains(hop.statusCode), !hop.location.isEmpty,
            let resolved = URL(string: hop.location, relativeTo: current)?.absoluteURL,
            inOrigin(resolved, of: original), resolved.absoluteString == hop.url.absoluteString,
            visited.insert(resolved.absoluteString).inserted else {
        throw PiliHTTPRequestContextError.invalidRequest
      }
      current = resolved
      return .dictionary(["statusCode": .integer(Int64(hop.statusCode)), "location": .string(hop.location),
                          "url": .string(hop.url.absoluteString)])
    }
    guard current.absoluteString == response.url.absoluteString,
          let cookieURL = URL(string: last.location, relativeTo: original)?.absoluteURL,
          inOrigin(cookieURL, of: original) else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    return encoded
  }

  private static let autoRedirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

  private static func terminalLocationArguments(
    _ response: PiliHTTPRequestResponseCookies, original: URL, policy: PiliPreparedHTTPPolicy
  ) throws -> [PiliBridgeValue]? {
    let isRedirect = (300..<400).contains(response.statusCode)
    guard let locations = response.locationValues else {
      guard !isRedirect || response.redirects.isEmpty else { throw PiliHTTPRequestContextError.invalidRequest }
      return nil
    }
    guard isRedirect, response.cookieSource == .separatedFields,
          !(policy.followRedirects && autoRedirectStatuses.contains(response.statusCode)),
          locations.isEmpty || !policy.followRedirects || policy.maxRedirects <= 0 || policy.retry?.installed == false else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    // Dio's extra writes resolve against the last raw Location reference.
    guard let base = URL(string: response.redirects.last?.location ?? original.absoluteString) else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    return try locations.map { location in
      guard !location.utf8.contains(0x0D), !location.utf8.contains(0x0A),
            let destination = location.isEmpty ? base : URL(string: location, relativeTo: base)?.absoluteURL,
            inOrigin(destination, of: original) else {
        throw PiliHTTPRequestContextError.invalidRequest
      }
      return .string(location)
    }
  }

  private static func inOrigin(_ url: URL, of original: URL) -> Bool {
    url.scheme?.lowercased() == original.scheme && url.host?.lowercased() == original.host &&
      (url.port ?? 443) == (original.port ?? 443) && url.user == nil && url.password == nil && url.fragment == nil
  }

  static func decodeReceipt(_ value: PiliBridgeValue) throws -> PiliHTTPRequestContextReceipt {
    let fields = try response(value)
    guard Set(fields.keys) == Set(["state", "cookiesSaved", "cookieCount", "executionAllowed"]),
          case .string(let state) = fields["state"], let outcome = PiliHTTPRequestContextOutcome(rawValue: state),
          case .bool(let saved) = fields["cookiesSaved"],
          case .integer(let count) = fields["cookieCount"], count >= 0, let cookieCount = Int(exactly: count),
          saved == (count > 0) else {
      throw PiliHTTPRequestContextError.invalidResponse
    }
    return PiliHTTPRequestContextReceipt(outcome: outcome, cookiesSaved: saved, cookieCount: cookieCount)
  }

  static func canonicalID(_ value: String) -> String? {
    guard value.utf8.count == 36, UUID(uuidString: value) != nil else { return nil }
    return value.lowercased()
  }

  private static func response(_ value: PiliBridgeValue) throws -> [String: PiliBridgeValue] {
    guard case .dictionary(let fields) = value, fields["executionAllowed"] == .bool(false) else {
      throw PiliHTTPRequestContextError.invalidResponse
    }
    if fields["state"] == .string("error") {
      guard Set(fields.keys) == Set(["state", "code", "executionAllowed"]),
            case .string(let code) = fields["code"], !code.isEmpty else {
        throw PiliHTTPRequestContextError.invalidResponse
      }
      throw PiliHTTPRequestContextError.serviceFailure(code: code)
    }
    return fields
  }

  private static func url(for purpose: PiliHTTPRequestPurpose) -> URL? {
    guard (1...30).contains(purpose.limit) else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "api.bilibili.com"
    components.path = "/x/v2/search/trending/ranking"
    components.queryItems = [URLQueryItem(name: "limit", value: String(purpose.limit))]
    return components.url
  }

  private static func headers(_ values: [String: PiliBridgeValue]) throws -> [String: String] {
    let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    var names = Set<String>()
    var result: [String: String] = [:]
    for (name, raw) in values {
      guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains),
            names.insert(name.lowercased()).inserted,
            !["host", "content-length"].contains(name.lowercased()),
            case .string(let value) = raw,
            value.unicodeScalars.allSatisfy({ $0.value != 13 && $0.value != 10 }) else {
        throw PiliHTTPRequestContextError.invalidResponse
      }
      result[name] = value
    }
    return result
  }
}
