import Foundation

enum PiliHTTPRequestPurpose: Sendable, Equatable {
  case searchTrending(limit: Int)

  var limit: Int {
    switch self {
    case .searchTrending(let limit): return limit
    }
  }
}

struct PiliHTTPRequestDescriptor: Sendable, Equatable {
  let url: URL
  let method: String
  let headers: [String: String]
}

/// Values owned by the caller; credential objects remain in the account adapter.
struct PiliHTTPRequestContext: Sendable, Equatable {
  let requestID: String
  let leaseID: String
  let request: PiliHTTPRequestDescriptor
  let revision: Int64
  let generation: Int64
  let limit: Int
  let policy: PiliPreparedHTTPPolicy
  let redirectIndex: Int64

  init(requestID: String, leaseID: String, request: PiliHTTPRequestDescriptor, revision: Int64,
       generation: Int64, limit: Int, policy: PiliPreparedHTTPPolicy, redirectIndex: Int64 = 0) {
    self.requestID = requestID
    self.leaseID = leaseID
    self.request = request
    self.revision = revision
    self.generation = generation
    self.limit = limit
    self.policy = policy
    self.redirectIndex = redirectIndex
  }

  var remainingRedirects: Int64? {
    guard policy.followRedirects, redirectIndex >= 0, policy.maxRedirects >= redirectIndex else { return nil }
    return policy.maxRedirects - redirectIndex
  }

  var mayReissueRedirect: Bool {
    policy.retry?.installed == true && (remainingRedirects ?? 0) > 0 && policy.responseType == "json"
      && policy.receiveDataWhenStatusError
  }

  // Context compatibility does not establish a verified Native transport.
  var executionAllowed: Bool { false }
}

enum PiliHTTPRequestCookieSource: String, Sendable, Equatable {
  case separatedFields
  case foundationCombined
  case dioLegacyPossiblyFolded
}

/// Preserve order and provenance; do not reserialize through Foundation Cookie.
struct PiliHTTPRequestResponseCookies: Sendable, Equatable {
  let url: URL
  let statusCode: Int
  let cookieSource: PiliHTTPRequestCookieSource
  let setCookieValues: [String]
  let redirects: [PiliHTTPRedirectHop]
  // Nil when the transport does not expose ordered terminal Location fields.
  let locationValues: [String]?

  init(url: URL, statusCode: Int, cookieSource: PiliHTTPRequestCookieSource, setCookieValues: [String],
       redirects: [PiliHTTPRedirectHop] = [], locationValues: [String]? = nil) {
    self.url = url
    self.statusCode = statusCode
    self.cookieSource = cookieSource
    self.setCookieValues = setCookieValues
    self.redirects = redirects
    self.locationValues = locationValues
  }
}

enum PiliHTTPRequestContextOutcome: String, Sendable, Equatable {
  case finished, abandoned, expired, consumed, unknown, revoked, closed
}

struct PiliHTTPRequestContextReceipt: Sendable, Equatable {
  let outcome: PiliHTTPRequestContextOutcome
  let cookiesSaved: Bool
  let cookieCount: Int
}

enum PiliHTTPRequestContextError: Error, Sendable, Equatable {
  case invalidRequest
  case invalidResponse
  case capacity
  case disposed
  case terminalTimeout
  case bridgeFailure(code: String)
  // No write outcome can be inferred from an error, including preclaim errors.
  case serviceFailure(code: String)
}

protocol PiliHTTPRequestContextProviding: Sendable {
  func prepare(_ purpose: PiliHTTPRequestPurpose) async throws -> PiliHTTPRequestContext
  func prepareRetry(_ context: PiliHTTPRequestContext, attempt: Int64) async throws -> [String: String]
  func prepareRedirect(_ context: PiliHTTPRequestContext, response: PiliHTTPResponseHead) async throws -> PiliHTTPRequestContext
  func finish(
    _ context: PiliHTTPRequestContext,
    response: PiliHTTPRequestResponseCookies
  ) async throws -> PiliHTTPRequestContextReceipt
  func abandon(_ context: PiliHTTPRequestContext) async throws -> PiliHTTPRequestContextReceipt
}
