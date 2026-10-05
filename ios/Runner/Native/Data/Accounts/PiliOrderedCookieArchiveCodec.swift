import Foundation

/// A bounded, standalone jar codec. It grants no account or network authority.
/// Parse before projecting object fields: Foundation's JSON dictionaries discard
/// duplicate keys, and Swift String equality can merge Dart-distinct UTF-16 keys.
struct PiliOrderedCookieArchiveCodec: Sendable {
  var limits: PiliOrderedCookieArchiveLimits = .standard

  func decode(_ data: Data) throws -> PiliOrderedCookieArchive {
    let limits = try limits.validated()
    guard data.count <= limits.maximumEncodedBytes else { throw Error.resourceLimit }
    var parser = OrderedCookieJSONParser(bytes: Array(data), limits: limits)
    let fields = try object(parser.parse(), keys: ["schemaVersion", "ignoreExpires", "provenance",
      "domainBuckets", "hostBuckets"])
    let schema = try integer(fields["schemaVersion"])
    guard schema == 2 else { throw Error.unsupportedSchema }
    let provenance = try object(required(fields["provenance"]), keys: ["capture", "priorPersistence",
      "legacyHiveAttributesIncomplete", "currentBucketOrderComplete"])
    guard let prior = PiliOrderedCookiePriorPersistence(rawValue: try ascii(provenance["priorPersistence"])) else {
      throw Error.invalidArchive
    }
    return try PiliOrderedCookieArchive(schemaVersion: 2, ignoreExpires: boolean(fields["ignoreExpires"]),
      provenance: PiliOrderedCookieProvenance(capture: ascii(provenance["capture"]), priorPersistence: prior,
        legacyHiveAttributesIncomplete: boolean(provenance["legacyHiveAttributesIncomplete"]),
        currentBucketOrderComplete: boolean(provenance["currentBucketOrderComplete"])),
      domainBuckets: buckets(fields["domainBuckets"]), hostBuckets: buckets(fields["hostBuckets"]))
      .validated(limits: limits)
  }

  func encode(_ archive: PiliOrderedCookieArchive) throws -> Data {
    let archive = try archive.validated(limits: limits)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(archive)
    // Apply the exact byte/depth/node envelope to locally constructed DTOs too.
    _ = try decode(data)
    return data
  }

  private typealias Error = PiliOrderedCookieArchiveError
  private typealias Value = OrderedCookieJSONValue

  private func buckets(_ value: Value?) throws -> [PiliOrderedCookieBucket] {
    try array(value).map { value in
      let fields = try object(value, keys: ["keyUnits", "paths"])
      return try PiliOrderedCookieBucket(keyUnits: units(fields["keyUnits"]), paths: array(fields["paths"]).map { value in
        let fields = try object(value, keys: ["keyUnits", "cookies"])
        return try PiliOrderedCookiePath(keyUnits: units(fields["keyUnits"]),
          cookies: array(fields["cookies"]).map(cookie))
      })
    }
  }

  private func cookie(_ value: Value) throws -> PiliOrderedCookieEntry {
    let f = try object(value, keys: ["keyUnits", "nameUnits", "valueUnits", "cookieDomainUnits",
      "cookiePathUnits", "secure", "httpOnly", "sameSite", "expiresMicroseconds", "maxAgeSeconds", "createdSeconds"])
    let sameSite: PiliOrderedCookieSameSite?
    if case .null = try required(f["sameSite"]) { sameSite = nil }
    else {
      guard let parsed = PiliOrderedCookieSameSite(rawValue: try ascii(f["sameSite"])) else { throw Error.invalidArchive }
      sameSite = parsed
    }
    return try PiliOrderedCookieEntry(keyUnits: units(f["keyUnits"]), nameUnits: units(f["nameUnits"]),
      valueUnits: units(f["valueUnits"]), cookieDomainUnits: optionalUnits(f["cookieDomainUnits"]),
      cookiePathUnits: optionalUnits(f["cookiePathUnits"]), secure: boolean(f["secure"]),
      httpOnly: boolean(f["httpOnly"]), sameSite: sameSite, expiresMicroseconds: optionalInteger(f["expiresMicroseconds"]),
      maxAgeSeconds: optionalInteger(f["maxAgeSeconds"]), createdSeconds: integer(f["createdSeconds"]))
  }

  private func object(_ value: Value, keys: Set<String>) throws -> [String: Value] {
    guard case .object(let pairs) = value, pairs.count == keys.count else { throw Error.invalidArchive }
    var fields: [String: Value] = [:]
    for pair in pairs {
      guard pair.key.units.allSatisfy({ $0 < 128 }) else { throw Error.invalidArchive }
      let key = String(decoding: pair.key.units, as: UTF16.self)
      guard keys.contains(key), fields.updateValue(pair.value, forKey: key) == nil else { throw Error.invalidArchive }
    }
    guard Set(fields.keys) == keys else { throw Error.invalidArchive }
    return fields
  }
  private func required(_ value: Value?) throws -> Value {
    guard let value else { throw Error.invalidArchive }; return value
  }
  private func array(_ value: Value?) throws -> [Value] {
    guard case .array(let values) = try required(value) else { throw Error.invalidArchive }; return values
  }
  private func integer(_ value: Value?) throws -> Int64 {
    guard case .number(let token) = try required(value),
          !token.contains("."), !token.contains("e"), !token.contains("E"),
          let value = Int64(token) else { throw Error.invalidArchive }
    return value
  }
  private func optionalInteger(_ value: Value?) throws -> Int64? {
    if case .null = try required(value) { return nil }; return try integer(value)
  }
  private func boolean(_ value: Value?) throws -> Bool {
    guard case .bool(let value) = try required(value) else { throw Error.invalidArchive }; return value
  }
  private func ascii(_ value: Value?) throws -> String {
    guard case .string(let units) = try required(value), units.units.allSatisfy({ $0 < 128 }) else {
      throw Error.invalidArchive
    }
    return String(decoding: units.units, as: UTF16.self)
  }
  private func units(_ value: Value?) throws -> PiliCookieUTF16 {
    let values = try array(value)
    // Global archive validation decides whether this is key/name/value capacity.
    guard values.count <= limits.maximumUTF16Units else { throw Error.resourceLimit }
    return try PiliCookieUTF16(units: values.map { value in
      guard let unit = UInt16(exactly: try integer(value)) else { throw Error.invalidArchive }; return unit
    })
  }
  private func optionalUnits(_ value: Value?) throws -> PiliCookieUTF16? {
    if case .null = try required(value) { return nil }; return try units(value)
  }
}

private struct OrderedCookieJSONPair {
  let key: PiliCookieUTF16
  let value: OrderedCookieJSONValue
}

private indirect enum OrderedCookieJSONValue {
  case null, bool(Bool), number(String), string(PiliCookieUTF16)
  case array([OrderedCookieJSONValue]), object([OrderedCookieJSONPair])
}

/// JSON grammar and limits are independent from schema validation. No Double or
/// NSNumber conversion can round a timestamp, coerce a Bool, or accept 1.0 as int.
private struct OrderedCookieJSONParser {
  let bytes: [UInt8]
  let limits: PiliOrderedCookieArchiveLimits
  private var cursor = 0
  private var nodes = 0
  private typealias Error = PiliOrderedCookieArchiveError

  init(bytes: [UInt8], limits: PiliOrderedCookieArchiveLimits) {
    self.bytes = bytes; self.limits = limits
  }

  mutating func parse() throws -> OrderedCookieJSONValue {
    let parsed = try value(depth: 1)
    whitespace()
    guard cursor == bytes.count else { throw Error.malformedJSON }
    return parsed
  }

  private mutating func countNode() throws {
    guard nodes < limits.maximumJSONNodes else { throw Error.resourceLimit }; nodes += 1
  }

  private mutating func value(depth: Int) throws -> OrderedCookieJSONValue {
    guard depth <= limits.maximumJSONDepth else { throw Error.resourceLimit }
    try countNode(); whitespace()
    guard cursor < bytes.count else { throw Error.malformedJSON }
    switch bytes[cursor] {
    case 110: try literal("null"); return .null
    case 116: try literal("true"); return .bool(true)
    case 102: try literal("false"); return .bool(false)
    case 34: return .string(try string())
    case 91:
      cursor += 1; whitespace()
      var result: [OrderedCookieJSONValue] = []
      if take(93) { return .array(result) }
      while true {
        result.append(try value(depth: depth + 1)); whitespace()
        if take(93) { return .array(result) }
        guard take(44) else { throw Error.malformedJSON }
      }
    case 123:
      cursor += 1; whitespace()
      var result: [OrderedCookieJSONPair] = []
      var keys = Set<PiliCookieUTF16>()
      if take(125) { return .object(result) }
      while true {
        whitespace(); try countNode()
        let key = try string()
        guard keys.insert(key).inserted else { throw Error.duplicateKey }
        whitespace(); guard take(58) else { throw Error.malformedJSON }
        result.append(OrderedCookieJSONPair(key: key, value: try value(depth: depth + 1))); whitespace()
        if take(125) { return .object(result) }
        guard take(44) else { throw Error.malformedJSON }
      }
    case 45, 48...57: return .number(try number())
    default: throw Error.malformedJSON
    }
  }

  private mutating func whitespace() {
    while cursor < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[cursor]) { cursor += 1 }
  }
  private mutating func take(_ byte: UInt8) -> Bool {
    guard cursor < bytes.count, bytes[cursor] == byte else { return false }; cursor += 1; return true
  }
  private mutating func literal(_ text: StaticString) throws {
    let expected = Array(text.description.utf8)
    guard bytes.count - cursor >= expected.count,
          Array(bytes[cursor..<(cursor + expected.count)]) == expected else { throw Error.malformedJSON }
    cursor += expected.count
  }

  private mutating func number() throws -> String {
    let start = cursor
    _ = take(45)
    guard cursor < bytes.count else { throw Error.malformedJSON }
    if take(48) {
      guard cursor == bytes.count || !(48...57).contains(bytes[cursor]) else { throw Error.malformedJSON }
    } else {
      guard (49...57).contains(bytes[cursor]) else { throw Error.malformedJSON }
      repeat { cursor += 1 } while cursor < bytes.count && (48...57).contains(bytes[cursor])
    }
    if take(46) { try digits() }
    if take(101) || take(69) { if !take(43) { _ = take(45) }; try digits() }
    return String(decoding: bytes[start..<cursor], as: UTF8.self)
  }
  private mutating func digits() throws {
    guard cursor < bytes.count, (48...57).contains(bytes[cursor]) else { throw Error.malformedJSON }
    repeat { cursor += 1 } while cursor < bytes.count && (48...57).contains(bytes[cursor])
  }

  private mutating func string() throws -> PiliCookieUTF16 {
    guard take(34) else { throw Error.malformedJSON }
    var units: [UInt16] = []
    var segment = cursor
    func appendSegment(_ bytes: ArraySlice<UInt8>, to units: inout [UInt16]) throws {
      guard let string = String(bytes: bytes, encoding: .utf8) else { throw Error.malformedJSON }
      units.append(contentsOf: string.utf16)
    }
    while cursor < bytes.count {
      let byte = bytes[cursor]
      if byte == 34 {
        try appendSegment(bytes[segment..<cursor], to: &units); cursor += 1
        return PiliCookieUTF16(units: units)
      }
      guard byte >= 32 else { throw Error.malformedJSON }
      if byte == 92 {
        try appendSegment(bytes[segment..<cursor], to: &units); cursor += 1
        guard cursor < bytes.count else { throw Error.malformedJSON }
        let escape = bytes[cursor]; cursor += 1
        switch escape {
        case 34, 47, 92: units.append(UInt16(escape))
        case 98: units.append(8)
        case 102: units.append(12)
        case 110: units.append(10)
        case 114: units.append(13)
        case 116: units.append(9)
        case 117:
          guard bytes.count - cursor >= 4 else { throw Error.malformedJSON }
          var unit: UInt16 = 0
          for byte in bytes[cursor..<(cursor + 4)] {
            let digit: UInt16
            switch byte {
            case 48...57: digit = UInt16(byte - 48)
            case 65...70: digit = UInt16(byte - 55)
            case 97...102: digit = UInt16(byte - 87)
            default: throw Error.malformedJSON
            }
            unit = unit * 16 + digit
          }
          cursor += 4; units.append(unit)
        default: throw Error.malformedJSON
        }
        segment = cursor
      } else { cursor += 1 }
    }
    throw Error.malformedJSON
  }
}
