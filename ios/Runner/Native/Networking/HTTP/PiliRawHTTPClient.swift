import Foundation
import PiliHTTPTransport

/// Runner adapter; endpoint/lease permission remains in Data, not this client.
final class PiliRawHTTPClient: PiliHTTPTransferring {
  private let transport: PiliRawHTTPTransport
  private let maximumRedirects: Int?

  init(profile: PiliRawHTTP11Profile, maximumBodyBytes: Int) throws {
    maximumRedirects = profile.redirectLimit
    transport = try PiliRawHTTPTransport(configuration: .init(
      protocolMode: .http11,
      connectMicroseconds: profile.connectMicroseconds,
      receiveIdleMicroseconds: profile.receiveIdleMicroseconds,
      poolIdleMicroseconds: profile.poolIdleMicroseconds,
      maxBodyBytes: maximumBodyBytes
    ))
  }

  deinit {
    let transport = self.transport
    Task { try? await transport.shutdown() }
  }

  func transfer(_ request: URLRequest, redirectLimit: Int?,
                onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void) async -> PiliHTTPTransferOutcome {
    let validLimit = redirectLimit.map { $0 >= 0 && $0 <= (maximumRedirects ?? -1) } ?? (maximumRedirects == nil)
    guard validLimit, request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
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
    let retryEvidence: PiliHTTPRetryEvidence? = switch outcome.retryReason {
    case .initialConnection?, .closedBeforeResponseHead?: .beforeResponseHead
    case .incompleteResponseBody?: .incompleteResponseBody
    case nil: nil
    }
    return .init(head: outcome.head.map(Self.head), body: body, retryEvidence: retryEvidence)
  }

  private static func head(_ value: PiliRawHTTPHead) -> PiliHTTPResponseHead {
    var headers: [String: String] = [:]
    for field in value.fields where field.name.lowercased() != "set-cookie" {
      let name = field.name.lowercased()
      if headers[name] == nil { headers[name] = field.value }
    }
    let locations = (300..<400).contains(value.statusCode) ? value.locationFields : nil
    return .init(url: value.url, statusCode: value.statusCode, headers: headers,
                 cookieFields: .separatedFields(value.setCookieFields),
                 redirects: value.redirects.map { .init(statusCode: $0.statusCode, location: $0.location, url: $0.url) },
                 locationValues: locations, requiresCompleteBodyForWriteBack: true)
  }
}

/// Outstanding executors retain their own client across retries and redirects.
actor PiliRawHTTPClientPool {
  private let maximumBodyBytes: Int
  private var current: (profile: PiliRawHTTP11Profile, client: PiliRawHTTPClient)?

  init(maximumBodyBytes: Int) {
    self.maximumBodyBytes = maximumBodyBytes
  }

  func client(for profile: PiliRawHTTP11Profile) throws -> PiliRawHTTPClient {
    if let current, current.profile == profile { return current.client }
    let client = try PiliRawHTTPClient(profile: profile, maximumBodyBytes: maximumBodyBytes)
    if profile.poolGeneration >= (current?.profile.poolGeneration ?? 0) {
      current = (profile, client)
    }
    return client
  }
}
