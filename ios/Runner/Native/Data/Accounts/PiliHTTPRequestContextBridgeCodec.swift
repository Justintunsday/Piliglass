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
    guard policy.acceptEncoding == validatedHeaders.first(where: { $0.key.lowercased() == "accept-encoding" })?.value,
          !policy.followRedirects else { throw PiliHTTPRequestContextError.invalidResponse }
    return PiliHTTPRequestContext(requestID: expectedID, leaseID: leaseID,
      request: PiliHTTPRequestDescriptor(url: expectedURL, method: "GET", headers: validatedHeaders),
      revision: revision, generation: generation, limit: purpose.limit, policy: policy)
  }

  static func finishArguments(
    context: PiliHTTPRequestContext,
    response: PiliHTTPRequestResponseCookies
  ) throws -> [String: PiliBridgeValue] {
    guard let requestID = canonicalID(context.requestID), canonicalID(context.leaseID) != nil,
          let expectedURL = url(for: .searchTrending(limit: context.limit)),
          context.request.url.absoluteString == expectedURL.absoluteString,
          context.request.method == "GET", response.url.absoluteString == expectedURL.absoluteString,
          (100...599).contains(response.statusCode) else {
      throw PiliHTTPRequestContextError.invalidRequest
    }
    return ["requestID": .string(requestID), "leaseID": .string(context.leaseID),
      "response": .dictionary(["url": .string(response.url.absoluteString),
        "statusCode": .integer(Int64(response.statusCode)), "cookieSource": .string(response.cookieSource.rawValue),
        "setCookieValues": .array(response.setCookieValues.map(PiliBridgeValue.string))])]
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
