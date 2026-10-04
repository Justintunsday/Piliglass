import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public struct PiliRawHTTPField: Sendable, Equatable, Codable {
  public let name: String
  public let value: String
  public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct PiliRawHTTPHead: Sendable, Equatable {
  public let url: URL
  public let statusCode: Int
  public let version: String
  public let fields: [PiliRawHTTPField]
  public var setCookieFields: [String] {
    fields.filter { $0.name.lowercased() == "set-cookie" }.map(\.value)
  }
}

public enum PiliRawHTTPFailure: String, Error, Sendable, Equatable {
  case invalidConfiguration, invalidRequest, cancelled, connectionTimeout
  case receiveIdleTimeout, sendIdleTimeout, deadline, bodyLimit, transport
}

public struct PiliRawHTTPOutcome: Sendable {
  public let head: PiliRawHTTPHead?
  public let body: Result<Data, PiliRawHTTPFailure>
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
  private let maxBodyBytes: Int
  private let allowsLoopbackHTTP: Bool

  public convenience init(configuration: Configuration = .init()) throws {
    try self.init(configuration: configuration, loopbackFixture: false)
  }

  // Only @testable package fixtures can use plain HTTP, strictly IPv4 loopback.
  internal init(configuration: Configuration, loopbackFixture: Bool) throws {
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
    // Disable injected global tracing; requests can carry credential fields.
    native.tracing.tracer = nil
    client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: native)
    maxBodyBytes = configuration.maxBodyBytes; allowsLoopbackHTTP = loopbackFixture
  }

  /// Composition owns shutdown after its outstanding transfers finish. The
  /// platform singleton event loop is borrowed and is never shut down here.
  public func shutdown() async throws { try await client.shutdown() }

  public func get(
    _ url: URL, headers: [PiliRawHTTPField] = [],
    onHead: @escaping @Sendable (PiliRawHTTPHead) -> Void = { _ in },
    onChunk: @escaping @Sendable (Int) -> Void = { _ in }
  ) async -> PiliRawHTTPOutcome {
    var observed: PiliRawHTTPHead?
    do {
      try Task.checkCancellation()
      guard url.user == nil, url.password == nil, url.fragment == nil, url.host != nil,
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
      var request = HTTPClientRequest(url: url.absoluteString)
      request.method = .GET
      for field in headers { request.headers.add(name: field.name, value: field.value) }
      // No resource-total deadline replacing a receive-idle timeout.
      let response = try await client.execute(request, deadline: .distantFuture)
      let head = PiliRawHTTPHead(url: response.url ?? url, statusCode: Int(response.status.code),
        version: "\(response.version.major).\(response.version.minor)",
        fields: response.headers.map { PiliRawHTTPField(name: $0.name, value: $0.value) })
      observed = head
      onHead(head)
      var body = Data()
      for try await chunk in response.body {
        try Task.checkCancellation()
        guard chunk.readableBytes <= maxBodyBytes - body.count else { throw PiliRawHTTPFailure.bodyLimit }
        body.append(contentsOf: chunk.readableBytesView)
        onChunk(chunk.readableBytes)
      }
      return .init(head: head, body: .success(body))
    } catch {
      return .init(head: observed, body: .failure(Self.failure(error)))
    }
  }

  private static func failure(_ error: Error) -> PiliRawHTTPFailure {
    if let error = error as? PiliRawHTTPFailure { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? HTTPClientError {
      if error == .cancelled { return .cancelled }
      if error == .connectTimeout { return .connectionTimeout }
      if error == .readTimeout { return .receiveIdleTimeout }
      if error == .writeTimeout { return .sendIdleTimeout }
      if error == .deadlineExceeded { return .deadline }
    }
    return .transport
  }
}
