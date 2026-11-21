import Foundation
import PiliHTTPTransport

/// Runner adapter; endpoint/lease permission remains in Data, not this client.
/// Runtime composition still uses Dart until this transport is accepted.
struct PiliRawHTTPClient: PiliHTTPTransferring {
  private let transport: PiliRawHTTPTransport
  private let redirectLimit: Int?

  init(profile: PiliRawHTTP11Profile, maximumBodyBytes: Int) throws {
    redirectLimit = profile.redirectLimit
    transport = try PiliRawHTTPTransport(configuration: .init(
      protocolMode: .http11,
      connectMicroseconds: profile.connectMicroseconds,
      receiveIdleMicroseconds: profile.receiveIdleMicroseconds,
      poolIdleMicroseconds: profile.poolIdleMicroseconds,
      maxBodyBytes: maximumBodyBytes
    ))
  }

  func shutdown() async throws { try await transport.shutdown() }

  func transfer(_ request: URLRequest,
                onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void) async -> PiliHTTPTransferOutcome {
    guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
          let url = request.url else {
      return .init(head: nil, body: .failure(.client(.invalidRequest)))
    }
    let outcome = await transport.get(url,
      headers: (request.allHTTPHeaderFields ?? [:]).map { .init(name: $0.key, value: $0.value) },
      sameOriginRedirectLimit: redirectLimit,
      onHead: { onHead(Self.head($0)) })
    let body = outcome.body.mapError { error -> PiliHTTPTransferFailure in
      error == .cancelled ? .cancelled : .client(.nativeTransport(kind: error.rawValue))
    }
    return .init(head: outcome.head.map(Self.head), body: body,
                 failedDuringInitialConnection: outcome.failedDuringInitialConnection)
  }

  private static func head(_ value: PiliRawHTTPHead) -> PiliHTTPResponseHead {
    var headers: [String: String] = [:]
    for field in value.fields where field.name.lowercased() != "set-cookie" {
      let name = field.name.lowercased()
      if headers[name] == nil { headers[name] = field.value }
    }
    return .init(url: value.url, statusCode: value.statusCode, headers: headers,
                 cookieFields: .separatedFields(value.setCookieFields),
                 redirects: value.redirects.map { .init(statusCode: $0.statusCode, location: $0.location, url: $0.url) })
  }
}
