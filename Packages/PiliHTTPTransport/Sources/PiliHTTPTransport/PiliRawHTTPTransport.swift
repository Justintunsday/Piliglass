import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
#if canImport(Network)
import Network
#endif

public struct PiliRawHTTPField: Sendable, Equatable, Codable {
  public let name: String
  public let value: String
  public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct PiliRawHTTPRedirectHop: Sendable, Equatable {
  public let statusCode: Int
  public let location: String
  public let url: URL
}

public struct PiliRawHTTPHead: Sendable, Equatable {
  public let url: URL
  public let statusCode: Int
  public let version: String
  public let fields: [PiliRawHTTPField]
  public let redirects: [PiliRawHTTPRedirectHop]
  public var setCookieFields: [String] {
    fields.filter { $0.name.lowercased() == "set-cookie" }.map(\.value)
  }
  public var locationFields: [String] {
    fields.filter { $0.name.lowercased() == "location" }.map(\.value)
  }
}

public enum PiliRawHTTPFailure: String, Error, Sendable, Equatable {
  case invalidConfiguration, invalidRequest, cancelled, connectionTimeout, connectionRefused
  case remoteConnectionClosed, receiveIdleTimeout, sendIdleTimeout, deadline, bodyLimit, transport
  case invalidRedirect, redirectLimit, redirectLoop, redirectOutsideOrigin
}

public enum PiliRawHTTPRetryReason: String, Sendable, Equatable {
  case initialConnection, closedBeforeResponseHead, incompleteResponseBody
}

public struct PiliRawHTTPOutcome: Sendable {
  public let head: PiliRawHTTPHead?
  public let body: Result<Data, PiliRawHTTPFailure>
  public let retryReason: PiliRawHTTPRetryReason?
  public var failedDuringInitialConnection: Bool { retryReason == .initialConnection }

  init(head: PiliRawHTTPHead?, body: Result<Data, PiliRawHTTPFailure>, retryReason: PiliRawHTTPRetryReason? = nil) {
    self.head = head
    self.body = body
    self.retryReason = retryReason
  }
}

/// An isolated candidate, not a declaration of Dio/iOS behavior parity. It has
/// no credential, Cookie, API, UI, playback or storage authority.
public final class PiliRawHTTPTransport: Sendable {
  public struct Configuration: Sendable {
    public enum ProtocolMode: Sendable, Equatable { case http11, automatic }
    public let protocolMode: ProtocolMode
    public let connectMicroseconds: Int64
    public let receiveIdleMicroseconds: Int64?
    public let sendIdleMicroseconds: Int64?
    public let poolIdleMicroseconds: Int64
    public let maxBodyBytes: Int

    public init(protocolMode: ProtocolMode = .http11, connectMicroseconds: Int64 = 10_000_000,
                receiveIdleMicroseconds: Int64? = 10_000_000,
                sendIdleMicroseconds: Int64? = nil, poolIdleMicroseconds: Int64 = 15_000_000,
                maxBodyBytes: Int = 4 * 1024 * 1024) {
      self.protocolMode = protocolMode; self.connectMicroseconds = connectMicroseconds
      self.receiveIdleMicroseconds = receiveIdleMicroseconds; self.sendIdleMicroseconds = sendIdleMicroseconds
      self.poolIdleMicroseconds = poolIdleMicroseconds; self.maxBodyBytes = maxBodyBytes
    }
  }

  private let client: HTTPClient
  private let protocolMode: Configuration.ProtocolMode
  private let maxBodyBytes: Int
  private let allowsLoopbackHTTP: Bool
  private let restrictsFixtureHost: Bool

  public convenience init(configuration: Configuration = .init()) throws {
    try self.init(configuration: configuration, loopbackFixture: false)
  }

  // Only @testable package fixtures can use plain HTTP, strictly IPv4 loopback.
  internal init(configuration: Configuration, loopbackFixture: Bool,
                fixtureTrustRootsFile: String? = nil) throws {
    guard fixtureTrustRootsFile == nil || loopbackFixture else {
      throw PiliRawHTTPFailure.invalidConfiguration
    }
    guard configuration.connectMicroseconds > 0, configuration.poolIdleMicroseconds >= 0,
          configuration.maxBodyBytes > 0 else { throw PiliRawHTTPFailure.invalidConfiguration }
    func duration(_ value: Int64) throws -> TimeAmount {
      guard value >= 0, value <= Int64.max / 1_000 else { throw PiliRawHTTPFailure.invalidConfiguration }
      return .nanoseconds(value * 1_000)
    }
    func optional(_ value: Int64?) throws -> TimeAmount? {
      guard let value else { return nil }
      // Dio zero means disabled. AHC nil connect means its own 10s default,
      // so the public connect field intentionally excludes zero/nil for now.
      if value == 0 { return nil }
      return try duration(value)
    }
    var pool = HTTPClient.Configuration.ConnectionPool(idleTimeout: try duration(configuration.poolIdleMicroseconds))
    pool.retryConnectionEstablishment = false
    var timeout = HTTPClient.Configuration.Timeout(connect: try duration(configuration.connectMicroseconds),
                                                    read: try optional(configuration.receiveIdleMicroseconds))
    timeout.write = try optional(configuration.sendIdleMicroseconds)
    var native = HTTPClient.Configuration(redirectConfiguration: .disallow, timeout: timeout,
                                         connectionPool: pool, decompression: .disabled)
    native.httpVersion = configuration.protocolMode == .http11 ? .http1Only : .automatic
    native.networkFrameworkWaitForConnectivity = false
    if let fixtureTrustRootsFile {
      var tls = native.tlsConfiguration ?? .makeClientConfiguration()
      tls.trustRoots = .file(fixtureTrustRootsFile)
      native.tlsConfiguration = tls
    }
    // Disable injected global tracing; requests can carry credential fields.
    native.tracing.tracer = nil
    client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: native)
    protocolMode = configuration.protocolMode
    maxBodyBytes = configuration.maxBodyBytes; allowsLoopbackHTTP = loopbackFixture
    restrictsFixtureHost = fixtureTrustRootsFile != nil
  }

  /// Composition owns shutdown after its outstanding transfers finish. The
  /// platform singleton event loop is borrowed and is never shut down here.
  public func shutdown() async throws { try await client.shutdown() }

  /// A nil limit returns the original response. An explicit limit follows only
  /// same-origin GET redirects, delivering callbacks for the terminal response.
  public func get(
    _ url: URL, headers: [PiliRawHTTPField] = [],
    sameOriginRedirectLimit: Int? = nil,
    onHead: @escaping @Sendable (PiliRawHTTPHead) -> Void = { _ in },
    afterHead: (@Sendable (PiliRawHTTPHead) async throws -> Void)? = nil,
    onChunk: @escaping @Sendable (Int) -> Void = { _ in }
  ) async -> PiliRawHTTPOutcome {
    enum Phase: Equatable { case preparing, awaitingHead, readingBody }
    var observed: PiliRawHTTPHead?
    var phase: Phase = .preparing
    var redirects: [PiliRawHTTPRedirectHop] = []
    do {
      try Task.checkCancellation()
      guard (sameOriginRedirectLimit ?? 0) >= 0,
            url.user == nil, url.password == nil, url.fragment == nil, url.host != nil,
            !restrictsFixtureHost || url.host == "127.0.0.1",
            url.scheme?.lowercased() == "https" ||
              (allowsLoopbackHTTP && url.scheme == "http" && url.host == "127.0.0.1") else {
        throw PiliRawHTTPFailure.invalidRequest
      }
      let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
      guard headers.allSatisfy({ field in
        !field.name.isEmpty && field.name.unicodeScalars.allSatisfy(token.contains)
          && !["host", "content-length"].contains(field.name.lowercased())
          && !field.value.contains("\r") && !field.value.contains("\n")
      }) else { throw PiliRawHTTPFailure.invalidRequest }
      var target = url
      var followed: Set<URL> = []
      while true {
        phase = .preparing
        try Task.checkCancellation()
        var request = HTTPClientRequest(url: target.absoluteString)
        request.method = .GET
        for field in headers { request.headers.add(name: field.name, value: field.value) }
        // No resource-total deadline replacing a receive-idle timeout.
        phase = .awaitingHead
        let response = try await client.execute(request, deadline: .distantFuture)
        phase = .readingBody
        let head = PiliRawHTTPHead(url: response.url ?? target, statusCode: Int(response.status.code),
          version: "\(response.version.major).\(response.version.minor)",
          fields: response.headers.map { PiliRawHTTPField(name: $0.name, value: $0.value) }, redirects: redirects)
        if let hop = try Self.redirectHop(head, origin: url, limit: sameOriginRedirectLimit, followed: &followed) {
          // Drain the accepted hop to permit connection reuse. Only the final
          // response's head, Cookie fields and chunks reach the caller.
          var remaining = maxBodyBytes
          for try await chunk in response.body {
            try Task.checkCancellation()
            guard chunk.readableBytes <= remaining else { throw PiliRawHTTPFailure.bodyLimit }
            remaining -= chunk.readableBytes
          }
          redirects.append(hop)
          target = hop.url
          continue
        }
        observed = head
        onHead(head)
        try await afterHead?(head)
        var body = Data()
        for try await chunk in response.body {
          try Task.checkCancellation()
          guard chunk.readableBytes <= maxBodyBytes - body.count else { throw PiliRawHTTPFailure.bodyLimit }
          body.append(contentsOf: chunk.readableBytesView)
          onChunk(chunk.readableBytes)
        }
        return .init(head: head, body: .success(body))
      }
    } catch {
      let failure = Self.failure(error)
      let retryReason: PiliRawHTTPRetryReason?
      if protocolMode == .http11, failure == .remoteConnectionClosed {
        // Automatic hops and their bodies are consumed by this transport.
        // Both failures restart the current prepared request, including its redirects.
        switch phase {
        case .awaitingHead: retryReason = .closedBeforeResponseHead
        case .readingBody: retryReason = .incompleteResponseBody
        case .preparing: retryReason = nil
        }
      } else if phase == .awaitingHead, redirects.isEmpty, (failure == .connectionRefused || failure == .connectionTimeout) {
        retryReason = .initialConnection
      } else {
        retryReason = nil
      }
      return .init(head: observed, body: .failure(failure), retryReason: retryReason)
    }
  }

  private static func redirectHop(_ head: PiliRawHTTPHead, origin: URL, limit: Int?,
                                  followed: inout Set<URL>) throws -> PiliRawHTTPRedirectHop? {
    guard let limit, [301, 302, 303, 307, 308].contains(head.statusCode) else { return nil }
    guard followed.count < limit else { throw PiliRawHTTPFailure.redirectLimit }
    let locations = head.locationFields
    guard locations.count == 1, let location = locations.first, !location.isEmpty,
          let target = URL(string: location, relativeTo: head.url)?.absoluteURL,
          target.user == nil, target.password == nil, target.fragment == nil else {
      throw PiliRawHTTPFailure.invalidRedirect
    }
    let scheme = origin.scheme?.lowercased()
    let defaultPort = scheme == "https" ? 443 : 80
    guard target.scheme?.lowercased() == scheme, target.host?.lowercased() == origin.host?.lowercased(),
          (target.port ?? defaultPort) == (origin.port ?? defaultPort) else {
      throw PiliRawHTTPFailure.redirectOutsideOrigin
    }
    guard followed.insert(target).inserted else { throw PiliRawHTTPFailure.redirectLoop }
    return PiliRawHTTPRedirectHop(statusCode: head.statusCode, location: location, url: target)
  }

  private static func failure(_ error: Error) -> PiliRawHTTPFailure {
    if let error = error as? PiliRawHTTPFailure { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? HTTPClientError {
      if error == .cancelled { return .cancelled }
      if error == .connectTimeout || error == .tlsHandshakeTimeout { return .connectionTimeout }
      if error == .remoteConnectionClosed { return .remoteConnectionClosed }
      if error == .readTimeout { return .receiveIdleTimeout }
      if error == .writeTimeout { return .sendIdleTimeout }
      if error == .deadlineExceeded { return .deadline }
    }
    if let error = error as? HTTPParserError, case .invalidEOFState = error { return .remoteConnectionClosed }
    #if canImport(Network)
    if let error = error as? HTTPClient.NWPOSIXError, error.errorCode == .ECONNREFUSED { return .connectionRefused }
    if let error = error as? NWError, case .posix(.ECONNREFUSED) = error { return .connectionRefused }
    #endif
    if let error = error as? IOError, error.errnoCode == POSIXErrorCode.ECONNREFUSED.rawValue {
      return .connectionRefused
    }
    return .transport
  }
}
