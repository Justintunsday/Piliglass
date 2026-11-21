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
  // A raw transport failure is not an NSError/NSURLErrorDomain numeric code.
  case nativeTransport(kind: String)
}

// A Foundation String array does not establish separated wire fields.
enum PiliHTTPResponseCookieFields: Sendable, Equatable {
  // Only transports that retain raw header tuples may use this provenance.
  case separatedFields([String])
  case foundationCombined([String])
  case unsupported
}

struct PiliHTTPResponseHead: Sendable, Equatable {
  let url: URL
  let statusCode: Int
  let headers: [String: String]
  let cookieFields: PiliHTTPResponseCookieFields
  let redirects: [PiliHTTPRedirectHop]

  init(url: URL, statusCode: Int, headers: [String: String], cookieFields: PiliHTTPResponseCookieFields,
       redirects: [PiliHTTPRedirectHop] = []) {
    self.url = url
    self.statusCode = statusCode
    self.headers = headers
    self.cookieFields = cookieFields
    self.redirects = redirects
  }
}

struct PiliHTTPRedirectHop: Sendable, Equatable {
  let statusCode: Int
  let location: String
  let url: URL
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
  // Raw connection-establishment failures on the initial URL can be retried.
  let failedDuringInitialConnection: Bool

  init(head: PiliHTTPResponseHead?, body: Result<Data, PiliHTTPTransferFailure>, transportErrorCode: Int? = nil,
       failedDuringInitialConnection: Bool = false) {
    self.head = head
    self.body = body
    self.transportErrorCode = transportErrorCode
    self.failedDuringInitialConnection = failedDuringInitialConnection
  }
}

protocol PiliHTTPTransferring: Sendable {
  // Observed head callbacks precede the returned outcome.
  func transfer(
    _ request: URLRequest,
    onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void
  ) async -> PiliHTTPTransferOutcome
}
