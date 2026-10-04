import CryptoKit
import Foundation

/// Supported Dart scalar values are explicit. Floating point / map / arbitrary
/// object descriptions remain in the Dart fallback until their bytes are proven.
enum PiliSigningValue: Sendable, Equatable {
  case string(String)
  case integer(Int64)
  case boolean(Bool)
  case strings([String])
  case null

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.string(let a), .string(let b)): return a.utf16.elementsEqual(b.utf16)
    case (.integer(let a), .integer(let b)): return a == b
    case (.boolean(let a), .boolean(let b)): return a == b
    case (.strings(let a), .strings(let b)):
      return a.count == b.count && zip(a, b).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
    case (.null, .null): return true
    default: return false
    }
  }

  fileprivate var dartDescription: String? {
    switch self {
    case .string(let value): return value
    case .integer(let value): return String(value)
    case .boolean(let value): return value ? "true" : "false"
    case .strings(let values): return "[" + values.joined(separator: ", ") + "]"
    case .null: return nil
    }
  }
}

/// Arrays preserve distinct UTF-16 keys that Swift String equality normalizes.
/// Repeated query fields come from `.strings`, as in Dart Iterable<String>.
struct PiliSigningField: Sendable, Equatable {
  let key: String
  let value: PiliSigningValue
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.key.utf16.elementsEqual(rhs.key.utf16) && lhs.value == rhs.value
  }
}

struct PiliSigningResult: Sendable, Equatable {
  let fields: [PiliSigningField]
  let query: String
  let digest: String
}

enum PiliSigningError: Error, Sendable, Equatable {
  case duplicateKey
  case nullValue
  case invalidMixinSource
  case unpairedMixinSurrogate
}

enum PiliNativeSigner {
  private static let mixinIndices = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31,
                                    58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19,
                                    29, 28, 14, 39, 12, 38, 41, 13]

  static func mixinKey(source: String) throws -> String {
    let sourceUnits = Array(source.utf16)
    guard sourceUnits.count > 58 else { throw PiliSigningError.invalidMixinSource }
    let units = mixinIndices.map { sourceUnits[$0] }
    var index = 0
    while index < units.count {
      let unit = units[index]
      if (0xD800...0xDBFF).contains(unit) {
        guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
          throw PiliSigningError.unpairedMixinSurrogate
        }
        index += 2
      } else {
        guard !(0xDC00...0xDFFF).contains(unit) else { throw PiliSigningError.unpairedMixinSurrogate }
        index += 1
      }
    }
    return String(decoding: units, as: UTF16.self)
  }

  static func wbi(
    fields: [PiliSigningField], mixinKey: String, epochSeconds: Int64
  ) throws -> PiliSigningResult {
    try validateUniqueKeys(fields)
    var result = replacing(fields, key: "wts", value: .integer(epochSeconds))
    let query = try sorted(result).map { field in
      guard let value = field.value.dartDescription else { throw PiliSigningError.nullValue }
      // Dart RegExp removes ASCII code units even when a combining scalar
      // follows them. Swift Character filtering would retain that punctuation.
      let filtered = String(decoding: value.utf8.filter {
        ![UInt8(33), 39, 40, 41, 42].contains($0)
      }, as: UTF8.self)
      return encodeComponent(field.key) + "=" + encodeComponent(filtered)
    }.joined(separator: "&")
    let digest = md5(query + mixinKey)
    result = replacing(result, key: "w_rid", value: .string(digest))
    return PiliSigningResult(fields: result, query: query, digest: digest)
  }

  static func app(
    fields: [PiliSigningField], appKey: String, appSecret: String, epochSeconds: Int64,
    allowReleaseNullValues: Bool = false
  ) throws -> PiliSigningResult {
    try validateUniqueKeys(fields)
    var result = replacing(fields, key: "appkey", value: .string(appKey))
    result = replacing(result, key: "ts", value: .string(String(epochSeconds)))
    let query = try appQuery(fields: result, allowReleaseNullValues: allowReleaseNullValues)
    let digest = md5(query + appSecret)
    result = replacing(result, key: "sign", value: .string(digest))
    return PiliSigningResult(fields: result, query: query, digest: digest)
  }

  /// Signing query helper. Endpoint form encoding is a separate transport
  /// contract; Dio may encode spaces differently in the submitted body.
  static func appQuery(fields: [PiliSigningField], allowReleaseNullValues: Bool = false) throws -> String {
    try validateUniqueKeys(fields)
    var queryFields: [String] = []
    for field in sorted(fields) {
      let values: [String?]
      switch field.value {
      case .strings(let strings): values = strings.map(Optional.some)
      default: values = [field.value.dartDescription]
      }
      for value in values {
        guard value != nil || allowReleaseNullValues else { throw PiliSigningError.nullValue }
        let key = encodeComponent(field.key)
        queryFields.append(value.map { $0.isEmpty ? key : key + "=" + encodeComponent($0) } ?? key)
      }
    }
    return queryFields.joined(separator: "&")
  }

  /// Dart Uri.encodeComponent keeps this exact ASCII set and encodes UTF-8
  /// bytes with uppercase hex. URLComponents has different query semantics.
  static func encodeComponent(_ string: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
    let hex = Array("0123456789ABCDEF".utf8)
    var result: [UInt8] = []
    for byte in string.utf8 {
      if allowed.contains(byte) { result.append(byte) }
      else { result.append(contentsOf: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]]) }
    }
    return String(decoding: result, as: UTF8.self)
  }

  private static func md5(_ string: String) -> String {
    Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private static func sorted(_ fields: [PiliSigningField]) -> [PiliSigningField] {
    fields.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
  }
  private static func replacing(
    _ fields: [PiliSigningField], key: String, value: PiliSigningValue
  ) -> [PiliSigningField] {
    var result = fields
    if let index = result.firstIndex(where: { $0.key.utf16.elementsEqual(key.utf16) }) {
      result[index] = PiliSigningField(key: key, value: value)
    } else { result.append(PiliSigningField(key: key, value: value)) }
    return result
  }
  private static func validateUniqueKeys(_ fields: [PiliSigningField]) throws {
    var seen = Set<[UInt16]>()
    for field in fields {
      guard seen.insert(Array(field.key.utf16)).inserted else { throw PiliSigningError.duplicateKey }
    }
  }
}
