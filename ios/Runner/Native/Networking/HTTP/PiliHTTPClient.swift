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
