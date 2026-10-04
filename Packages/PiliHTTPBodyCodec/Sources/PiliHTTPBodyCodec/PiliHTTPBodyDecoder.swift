import CPiliHTTPBodyCodec
import Foundation

public enum PiliHTTPBodyDecodeFailure: Error, Sendable, Equatable {
  case invalidBudget, malformedCompression, outputLimit, allocationFailure
}

/// Pure candidate body pipeline. It never reads credentials, cookies, network,
/// UI or player state and is not a runtime capability/parity declaration.
public enum PiliHTTPBodyDecoder {
  public static func decode(body: Data, headers: [String: [String]], maximumOutputBytes: Int) throws -> Data {
    guard maximumOutputBytes >= 0 else { throw PiliHTTPBodyDecodeFailure.invalidBudget }
    let codec: Int32
    // Matches Request.responseBytesDecoder: first normalized header value,
    // exact case/token, no comma splitting or unproven stacked encodings.
    switch headers["content-encoding"]?.first {
    case "gzip": codec = 1
    case "br": codec = 2
    default:
      guard body.count <= maximumOutputBytes else { throw PiliHTTPBodyDecodeFailure.outputLimit }
      return body
    }
    let result = body.withUnsafeBytes { bytes in
      pili_http_body_decode(bytes.bindMemory(to: UInt8.self).baseAddress,
                            body.count, codec, maximumOutputBytes)
    }
    defer { pili_http_body_release(result.bytes) }
    switch result.status {
    case 0:
      guard let bytes = result.bytes else { return Data() }
      return Data(bytes: bytes, count: result.count)
    case 1: throw PiliHTTPBodyDecodeFailure.malformedCompression
    case 2: throw PiliHTTPBodyDecodeFailure.outputLimit
    default: throw PiliHTTPBodyDecodeFailure.allocationFailure
    }
  }

  /// Dart utf8.decode(..., allowMalformed:true) strips one initial UTF8 BOM.
  /// Malformed replacement grouping is tested against the actual Dart VM.
  public static func utf8AllowMalformed(_ body: Data) -> String {
    let bytes = body.starts(with: [0xEF, 0xBB, 0xBF]) ? body.dropFirst(3) : body[body.startIndex...]
    return String(decoding: bytes, as: UTF8.self)
  }
}
