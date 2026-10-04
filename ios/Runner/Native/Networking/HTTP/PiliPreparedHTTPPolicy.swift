import Foundation

/// An immutable description of the Dart request's actual transport inputs.
/// Capability and permission to execute are separate, later migration gates.
struct PiliPreparedHTTPPolicy: Sendable, Equatable {
  enum ClientMode: String, Sendable { case main, http11 }
  enum Decoder: String, Sendable { case manualCompressionUTF8, unknown }
  enum Issue: String, Sendable, CaseIterable {
    case poolNotInstalled, poolInstallationFailed, adapterChanged, http11FactoryChanged
    case connectionManagerChanged, fallbackAdapterChanged, fallbackClientChanged
    case retryNotDescribed, decoderChanged, acceptEncodingNotDescribed

    var affectsPool: Bool {
      switch self {
      case .retryNotDescribed, .decoderChanged, .acceptEncodingNotDescribed: return false
      default: return true
      }
    }
  }
  struct Proxy: Sendable, Equatable { let host: String; let port: Int64 }
  struct Pool: Sendable, Equatable {
    let http2Enabled: Bool
    let idleTimeoutMicroseconds: Int64
    let http11AcceptsBadCertificate: Bool
    let http2AcceptsBadCertificate: Bool?
    let proxy: Proxy?
    let autoUncompress: Bool
    let http2ALPN: [String]
  }
  struct Retry: Sendable, Equatable {
    let installed: Bool
    let count: Int64
    let delayMilliseconds: Int64?
  }

  let version: Int64
  let poolGeneration: Int64
  let clientMode: ClientMode
  let pool: Pool?
  let retry: Retry?
  let connectTimeoutMicroseconds: Int64?
  let receiveIdleTimeoutMicroseconds: Int64?
  let sendTimeoutMicroseconds: Int64?
  let transformTimeoutMicroseconds: Int64?
  let receiveDataWhenStatusError: Bool
  let persistentConnection: Bool
  let followRedirects: Bool
  let maxRedirects: Int64
  let acceptEncoding: String?
  let responseType: String
  let decoder: Decoder
  let issues: [Issue]
  var isDescribed: Bool { issues.isEmpty }
}
