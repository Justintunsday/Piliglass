import Foundation

protocol PiliHTTPClient: Sendable {
  // Return HTTP error responses too: the account layer must receive Set-Cookie
  // before a service validates status or decodes an API envelope.
  func send(_ request: URLRequest) async throws -> PiliHTTPResponse
}

struct PiliHTTPResponse: Sendable, Equatable {
  let url: URL
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  func header(named name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

enum PiliHTTPClientError: Error, Sendable, Equatable {
  case invalidRequest
  case invalidResponse
  case transport(code: Int)
}

// A Foundation String array does not establish separated wire fields.
enum PiliHTTPResponseCookieFields: Sendable, Equatable {
  case foundationCombined([String])
  case unsupported
}

struct PiliHTTPResponseHead: Sendable, Equatable {
  let url: URL
  let statusCode: Int
  let headers: [String: String]
  let cookieFields: PiliHTTPResponseCookieFields
}

enum PiliHTTPTransferFailure: Error, Sendable, Equatable {
  case cancelled
  case client(PiliHTTPClientError)
}

struct PiliHTTPTransferOutcome: Sendable {
  let head: PiliHTTPResponseHead?
  let body: Result<Data, PiliHTTPTransferFailure>
  // Only an actual completion error in NSURLErrorDomain supplies this value.
  let transportErrorCode: Int?

  init(head: PiliHTTPResponseHead?, body: Result<Data, PiliHTTPTransferFailure>, transportErrorCode: Int? = nil) {
    self.head = head
    self.body = body
    self.transportErrorCode = transportErrorCode
  }
}

protocol PiliHTTPTransferring: Sendable {
  func transfer(
    _ request: URLRequest,
    onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void
  ) async -> PiliHTTPTransferOutcome
}
