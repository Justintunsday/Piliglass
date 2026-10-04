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
  func finish(
    _ context: PiliHTTPRequestContext,
    response: PiliHTTPRequestResponseCookies
  ) async throws -> PiliHTTPRequestContextReceipt
  func abandon(_ context: PiliHTTPRequestContext) async throws -> PiliHTTPRequestContextReceipt
}
