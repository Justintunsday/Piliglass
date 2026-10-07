import Foundation

// Compiles the integrated production DTO/codec sources listed by the companion
// driver. Grants no account authority; every comparison uses fresh actual Dart
// goldens and an independent structural oracle.
private enum FixtureFailure: Error { case failed(String) }
private struct OracleField: Equatable {
  let key: String
  let value: OracleJSON
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.key.utf16.elementsEqual(rhs.key.utf16) && lhs.value == rhs.value
  }
}

/// Independent valid-oracle reader. Number tokens remain exact decimal text;
/// it never uses NSNumber/Double or the production strict JSON parser. Arrays,
/// required nulls and UTF16 unit sequences retain their original order/values.
private indirect enum OracleJSON: Equatable {
  case null, bool(Bool), number(String), string(String)
  case array([OracleJSON]), object([OracleField])

  static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): true
    case (.bool(let a), .bool(let b)): a == b
    case (.number(let a), .number(let b)): a == b
    case (.string(let a), .string(let b)): a.utf16.elementsEqual(b.utf16)
    case (.array(let a), .array(let b)): a == b
    case (.object(let a), .object(let b)):
      a.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) } ==
        b.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
    default: false
    }
  }

  func field(_ key: String) throws -> Self {
    guard case .object(let fields) = self,
          let result = fields.first(where: { $0.key.utf16.elementsEqual(key.utf16) }) else {
      throw FixtureFailure.failed("Missing original oracle field: \(key)")
    }
    return result.value
  }
  func values() throws -> [Self] {
    guard case .array(let values) = self else { throw FixtureFailure.failed("Expected original array") }
    return values
  }
  func text() throws -> String {
    guard case .string(let text) = self else { throw FixtureFailure.failed("Expected original String") }
    return text
  }
  func integer() throws -> Int64 {
    guard case .number(let token) = self, !token.contains("."), !token.contains("e"),
          !token.contains("E"), let value = Int64(token) else {
      throw FixtureFailure.failed("Expected exact original Int64 token")
    }
    return value
  }
  func replacing(_ path: [OraclePath], with replacement: Self?) throws -> Self {
    guard let first = path.first else {
      guard let replacement else { throw FixtureFailure.failed("Cannot remove root") }
      return replacement
    }
    let tail = Array(path.dropFirst())
    switch (self, first) {
    case (.object(let fields), .field(let key)):
      guard let index = fields.firstIndex(where: { $0.key == key }) else {
        throw FixtureFailure.failed("Mutation path field absent")
      }
      var result = fields
      if tail.isEmpty, replacement == nil { result.remove(at: index) }
      else { result[index] = .init(key: key, value: try fields[index].value.replacing(tail, with: replacement)) }
      return .object(result)
    case (.array(let values), .index(let index)):
      guard values.indices.contains(index) else { throw FixtureFailure.failed("Mutation index absent") }
      var result = values
      if tail.isEmpty, replacement == nil { result.remove(at: index) }
      else { result[index] = try values[index].replacing(tail, with: replacement) }
      return .array(result)
    default: throw FixtureFailure.failed("Mutation path has wrong original shape")
    }
  }
  func wire() throws -> Data {
    func string(_ text: String) throws -> String {
      guard let result = String(data: try JSONEncoder().encode(text), encoding: .utf8) else {
        throw FixtureFailure.failed("String encoding failed")
      }
      return result
    }
    func emit(_ value: Self) throws -> String {
      switch value {
      case .null: return "null"
      case .bool(let flag): return flag ? "true" : "false"
      case .number(let token): return token
      case .string(let text): return try string(text)
      case .array(let values): return "[" + (try values.map(emit)).joined(separator: ",") + "]"
      case .object(let fields):
        return "{" + (try fields.map { try string($0.key) + ":" + emit($0.value) }).joined(separator: ",") + "}"
      }
    }
    return Data(try emit(self).utf8)
  }
}
private enum OraclePath { case field(String), index(Int) }

/// Minimal independent grammar for the trusted actual-Dart artifact. Strict
/// rejection tests are sent to the production codec, never decided here.
private struct OracleReader {
  let bytes: [UInt8]
  private var cursor = 0
  init(_ data: Data) { bytes = Array(data) }
  mutating func read() throws -> OracleJSON {
    let result = try value(); whitespace()
    guard cursor == bytes.count else { throw FixtureFailure.failed("Trailing oracle data") }
    return result
  }
  private mutating func whitespace() {
    while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
  }
  private mutating func take(_ byte: UInt8) -> Bool {
    whitespace()
    guard cursor < bytes.count, bytes[cursor] == byte else { return false }
    cursor += 1; return true
  }
  private mutating func literal(_ text: String) throws {
    let token = Array(text.utf8)
    guard cursor + token.count <= bytes.count,
          Array(bytes[cursor..<(cursor + token.count)]) == token else {
      throw FixtureFailure.failed("Invalid oracle literal")
    }
    cursor += token.count
  }
  private mutating func string() throws -> String {
    whitespace(); let start = cursor
    guard take(34) else { throw FixtureFailure.failed("Missing oracle String") }
    var escaped = false
    while cursor < bytes.count {
      let byte = bytes[cursor]; cursor += 1
      if escaped { escaped = false; continue }
      if byte == 92 { escaped = true; continue }
      if byte == 34 {
        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor]))
      }
    }
    throw FixtureFailure.failed("Unterminated oracle String")
  }
  private mutating func value() throws -> OracleJSON {
    whitespace()
    guard cursor < bytes.count else { throw FixtureFailure.failed("Missing oracle value") }
    switch bytes[cursor] {
    case 110: try literal("null"); return .null
    case 116: try literal("true"); return .bool(true)
    case 102: try literal("false"); return .bool(false)
    case 34: return .string(try string())
    case 91:
      cursor += 1; var values: [OracleJSON] = []
      if take(93) { return .array(values) }
      repeat { values.append(try value()); if take(93) { return .array(values) } } while take(44)
      throw FixtureFailure.failed("Invalid oracle array")
    case 123:
      cursor += 1; var fields: [OracleField] = []
      if take(125) { return .object(fields) }
      repeat {
        let key = try string()
        guard take(58) else { throw FixtureFailure.failed("Missing oracle colon") }
        fields.append(.init(key: key, value: try value()))
        if take(125) { return .object(fields) }
      } while take(44)
      throw FixtureFailure.failed("Invalid oracle object")
    default:
      let start = cursor
      while cursor < bytes.count,
            bytes[cursor] == 45 || bytes[cursor] == 43 || bytes[cursor] == 46 ||
            bytes[cursor] == 101 || bytes[cursor] == 69 || (48...57).contains(bytes[cursor]) {
        cursor += 1
      }
      guard cursor > start else { throw FixtureFailure.failed("Invalid oracle number") }
      return .number(String(decoding: bytes[start..<cursor], as: UTF8.self))
    }
  }
}

@main
private struct NativeAccountEnvelopeFixture {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else { throw FixtureFailure.failed("Fresh live/cold Dart goldens required") }
    let codec = PiliAccountLiveMemoryShadowCodec()
    var checks = 0, observed = 0, negatives = 0
    func check(_ condition: Bool, _ reason: String) throws {
      guard condition else { throw FixtureFailure.failed(reason) }; checks += 1
    }
    func read(_ data: Data) throws -> OracleJSON { var reader = OracleReader(data); return try reader.read() }
    func items(_ path: String) throws -> (OracleJSON, [OracleJSON]) {
      let wrapper = try read(Data(contentsOf: URL(fileURLWithPath: path)))
      try check(try wrapper.field("schemaVersion").integer() == 1, "Fixture wrapper schema")
      try check(try wrapper.field("runtimeCutover") == .bool(false), "Fixture must remain runtime off")
      try check(try wrapper.field("durableIdentityConfigured") == .bool(false), "No durable identity fixture")
      try check(try wrapper.field("clockPolicy").field("injectedClock") == .bool(false), "No injected Dart clock")
      try check(try wrapper.field("clockPolicy").field("kind") == .string("actualDartDateTimeNow"), "Actual Dart wall-clock label")
      try check(try wrapper.field("clockPolicy").field("exactBoundaryProof") == .bool(false), "No exact-boundary clock claim")
      return (wrapper, try wrapper.field("cases").values())
    }
    var originals: [String: OracleJSON] = [:]
    for path in CommandLine.arguments.dropFirst() {
      let (_, cases) = try items(path)
      for item in cases {
        let id = try item.field("id").text()
        guard originals[id] == nil else { throw FixtureFailure.failed("Duplicate source case ID") }
        let original = try item.field("envelope")
        let candidate = try codec.decode(original.wire())
        let encoded = try codec.encode(candidate)
        try check(try read(encoded) == original, "Lost original fields/null/int/UTF16/arrays: \(id)")
        originals[id] = original; observed += 1
      }
    }
    let required: Set<String> = ["anonymous-empty-jar", "stored-10-2-owner-2-10",
      "same-key-replacement-owner-10-2", "distinct-raw-02-and-2-equal-mid", "zero-and-negative-login-mid",
      "four-effective-purposes", "temporary-heartbeat-anonymous-history-main", "anonymous-persisted-purposes",
      "raw-utf16-full-attributes-nullable-credentials", "actual-hive-reopen-before-refresh"]
    try check(Set(originals.keys) == required && observed == 10, "Missing/excess actual Dart observations")
    func source(_ id: String) throws -> OracleJSON {
      guard let value = originals[id] else { throw FixtureFailure.failed("Missing required source case") }; return value
    }
    func rawKey(_ node: OracleJSON) throws -> [UInt16] {
      try node.values().map { value in
        guard let unit = UInt16(exactly: try value.integer()) else { throw FixtureFailure.failed("Bad original UTF16") }
        return unit
      }
    }
    func orderKeys(_ node: OracleJSON, _ field: String) throws -> [[UInt16]] {
      try node.field(field).values().map { try rawKey($0.field("keyUnits")) }
    }
    func ascii(_ text: String) -> [UInt16] { Array(text.utf16) }
    let ordered = try source("stored-10-2-owner-2-10")
    try check(try orderKeys(ordered, "storedOrder") == [ascii("10"), ascii("2")], "Real Box order 10/2")
    try check(try orderKeys(ordered, "ownerOrder") == [ascii("2"), ascii("10")], "Real live owner order 2/10")
    let replaced = try source("same-key-replacement-owner-10-2")
    try check(try orderKeys(replaced, "ownerOrder") == [ascii("10"), ascii("2")], "Replacement reinserts owner")
    let equalMID = try source("distinct-raw-02-and-2-equal-mid")
    let equalRecords = try equalMID.field("records").values()
    try check(try orderKeys(equalMID, "storedOrder") == [ascii("02"), ascii("2")], "Raw owner keys remain distinct")
    try check(try equalRecords[1].field("mid").integer() == 2 && equalRecords[2].field("mid").integer() == 2,
      "Equal MID must not collapse actual owners")
    let nonpositiveEnvelope = try source("zero-and-negative-login-mid")
    let nonpositive = try nonpositiveEnvelope.field("records").values()
    try check(try nonpositive[1].field("mid").integer() == -2 && nonpositive[2].field("mid").integer() == 0,
      "Actual negative/zero profile MIDs")
    try check(try nonpositive[1].field("isLogin") == .bool(true) && nonpositive[2].field("isLogin") == .bool(true),
      "Source login policy does not follow MID positivity")
    try check(try nonpositiveEnvelope.field("history").integer() == 2,
      "Heartbeat zero-MID login uses its actual owner for history")
    let full = try source("four-effective-purposes")
    try check(try full.field("selections") == .array([1, 2, 3, 4].map { .number(String($0)) }), "Four actual purpose slots")
    let temporary = try source("temporary-heartbeat-anonymous-history-main")
    try check(try temporary.field("selections") == .array([1, 0, 3, 4].map { .number(String($0)) }), "Actual temporary slot")
    try check(try temporary.field("history").integer() == 1, "Actual temporary history fallback")
    let anonPurposes = try source("anonymous-persisted-purposes").field("records").values()[0]
    try check(try anonPurposes.field("persistedPurposes") == .array([.string("video"), .string("main")]), "Mutable anonymous purposes")
    let rich = try source("raw-utf16-full-attributes-nullable-credentials")
    let richRecord = try rich.field("records").values()[1]
    try check(try richRecord.field("accessKeyUnits") == .null && richRecord.field("refreshTokenUnits") == .null, "Required nil credentials")
    let domainKeys = try richRecord.field("jar").field("domainBuckets").values().map { try rawKey($0.field("keyUnits")) }
    try check(domainKeys.contains([233]) && domainKeys.contains([101, 769]) &&
      domainKeys.contains([55296]) && domainKeys.contains([56320]), "Exact canonical/unpaired UTF16 source keys")
    func cookie(_ jar: OracleJSON, domain: String, path: String, key: String) throws -> OracleJSON {
      for bucket in try jar.field("domainBuckets").values() {
        guard try rawKey(bucket.field("keyUnits")) == ascii(domain) else { continue }
        for item in try bucket.field("paths").values() {
          guard try rawKey(item.field("keyUnits")) == ascii(path) else { continue }
          for value in try item.field("cookies").values() {
            if try rawKey(value.field("keyUnits")) == ascii(key) { return value }
          }
        }
      }
      throw FixtureFailure.failed("Actual source Cookie absent")
    }
    let richJar = try richRecord.field("jar")
    let richCookie = try cookie(richJar, domain: "attribute-map-key.example", path: "/different-map-path", key: "alias-map-name")
    try check(try rawKey(richCookie.field("nameUnits")) == ascii("actual-cookie-name"), "Actual key/name mismatch")
    try check(try richCookie.field("secure") == .bool(true) && richCookie.field("httpOnly") == .bool(true), "Actual full boolean attributes")
    try check(try richCookie.field("sameSite") == .string("Strict") && richCookie.field("maxAgeSeconds").integer() == 90,
      "Actual SameSite/MaxAge attributes")
    try check(try richCookie.field("expiresMicroseconds").integer() > 0 && richCookie.field("createdSeconds").integer() >= 0,
      "Actual expiry/creation observations")
    try check(try richJar.field("hostBuckets").values().contains(where: {
      try $0.field("paths").values().isEmpty
    }), "Actual empty outer buckets")
    let cold = try source("actual-hive-reopen-before-refresh")
    try check(try orderKeys(cold, "storedOrder") == [ascii("10"), ascii("2")] &&
      orderKeys(cold, "ownerOrder") == [ascii("10"), ascii("2")], "Actual cold Box/owner order")
    try check(try cold.field("selections") == .array(Array(repeating: .number("0"), count: 4)), "Cold capture precedes refresh")
    let coldRecords = try cold.field("records").values()
    try check(try coldRecords[1].field("activated") == .bool(false) && coldRecords[2].field("activated") == .bool(false), "Actual type9 activated loss")
    let coldJar = try coldRecords[2].field("jar")
    try check(try coldJar.field("hostBuckets").values().isEmpty && coldJar.field("domainBuckets").values().count == 1,
      "Actual type8 root-only restore lost extra maps")
    let (coldWrapper, _) = try items(CommandLine.arguments[2])
    let preHive = try coldWrapper.field("preHiveJarObservations").values()
    try check(preHive.count == 2, "Actual pre-Hive jar observations")
    let preCookie = try cookie(preHive[0].field("jar"), domain: "bilibili.com", path: "/", key: "root-map-alias")
    let restoredCookie = try cookie(coldJar, domain: "bilibili.com", path: "/", key: "surviving-cookie-name")
    try check(try preCookie.field("secure") == .bool(true) && preCookie.field("sameSite") == .string("Lax"), "Actual pre-Hive full root attributes")
    try check(try restoredCookie.field("secure") == .bool(false) && restoredCookie.field("httpOnly") == .bool(false) &&
      restoredCookie.field("sameSite") == .null && restoredCookie.field("maxAgeSeconds") == .null &&
      restoredCookie.field("expiresMicroseconds") == .null, "Actual legacy root attributes lost")

    func failure(_ label: String, _ data: Data, _ expected: PiliAccountLiveMemoryShadowError,
                 limits: PiliOrderedCookieArchiveLimits = .standard) throws {
      do {
        _ = try PiliAccountLiveMemoryShadowCodec(limits: limits).decode(data)
        throw FixtureFailure.failed("Accepted negative case: \(label)")
      } catch let actual as PiliAccountLiveMemoryShadowError {
        try check(actual == expected, "Wrong exact error \(label): \(actual), expected \(expected)")
        negatives += 1
      }
    }
    func changed(_ label: String, _ original: OracleJSON, _ path: [OraclePath], _ value: OracleJSON?,
                 _ error: PiliAccountLiveMemoryShadowError = .invalidEnvelope) throws {
      try failure(label, original.replacing(path, with: value).wire(), error)
    }
    let rootWire = try ordered.wire()
    guard let rootText = String(data: rootWire, encoding: .utf8), rootText.first == "{" else {
      throw FixtureFailure.failed("Original root object absent")
    }
    try failure("duplicate-field", Data(("{\"schemaVersion\":2," + String(rootText.dropFirst())).utf8), .duplicateKey)
    try failure("escaped-duplicate-field", Data(("{\"schema\\u0056ersion\":2," + String(rootText.dropFirst())).utf8), .duplicateKey)
    try failure("invalid-utf8", Data([123, 34, 120, 34, 58, 34, 255, 34, 125]), .malformedJSON)
    try failure("unknown-field", Data(("{\"unknown\":null," + String(rootText.dropFirst())).utf8), .invalidEnvelope)
    try changed("missing-required-null", ordered, [.field("records"), .index(0), .field("storageKeyUnits")], nil)
    try changed("unsupported-schema", ordered, [.field("schemaVersion")], .number("3"), .unsupportedSchema)
    for (label, value) in [("bool-as-int", OracleJSON.bool(true)), ("decimal-int", .number("1.0")),
                           ("exponent-int", .number("1e0")), ("overflow-int", .number("9223372036854775808"))] {
      try changed(label, ordered, [.field("revision")], value)
    }
    for flag in ["durableIdentityConfigured", "durabilityVerified", "authoritySwitchAllowed", "nativeWritesAllowed"] {
      try changed("enabled-\(flag)", ordered, [.field(flag)], .bool(true))
    }
    try changed("wrong-scope", ordered, [.field("scope")], .string("NativeActive"))
    try changed("long-policy-string", ordered, [.field("scope")], .string(String(repeating: "x", count: 100_000)))
    try changed("wrong-identity-scope", ordered, [.field("identityScope")], .string("durable"))
    try changed("nonboolean-capability", ordered, [.field("nativeWritesAllowed")], .number("0"))
    try changed("record-ordinal", ordered, [.field("records"), .index(1), .field("record")], .number("2"))
    let generation = try ordered.field("records").values()[0].field("generation")
    try changed("duplicate-generation", ordered, [.field("records"), .index(1), .field("generation")], generation)
    try changed("anonymous-login", ordered, [.field("records"), .index(0), .field("isLogin")], .bool(true))
    try changed("stored-order-reversed", ordered, [.field("storedOrder")], .array(Array(try ordered.field("storedOrder").values().reversed())))
    let ownerFirst = try ordered.field("ownerOrder").values()[0]
    try changed("duplicate-owner-reference", ordered, [.field("ownerOrder"), .index(1)], ownerFirst)
    try changed("wrong-selection-purposes", ordered, [.field("selectionPurposes")], .array([.string("video"), .string("heartbeat"), .string("recommend"), .string("main")]))
    try changed("out-of-range-selection", ordered, [.field("selections"), .index(0)], .number("256"))
    try changed("missing-fourth-selection", ordered, [.field("selections")], .array(Array(repeating: .number("0"), count: 3)))
    try changed("large-selection-list", ordered, [.field("selections")], .array(Array(repeating: .number("0"), count: 1024)))
    try changed("duplicate-persisted-purpose", ordered, [.field("records"), .index(1), .field("persistedPurposes")], .array([.string("main"), .string("main")]))
    try changed("unknown-persisted-purpose", ordered, [.field("records"), .index(1), .field("persistedPurposes")], .array([.string("unknown")]))
    try changed("long-persisted-purpose", ordered, [.field("records"), .index(1), .field("persistedPurposes")],
      .array([.string(String(repeating: "x", count: 100_000))]))
    try changed("incorrect-history", temporary, [.field("history")], .number("0"))
    try changed("invalid-utf16-unit", ordered, [.field("records"), .index(1), .field("storageKeyUnits"), .index(0)], .number("65536"))
    let duplicateKey = try ordered.field("records").values()[1].field("storageKeyUnits")
    try changed("duplicate-raw-storage-key", ordered, [.field("records"), .index(2), .field("storageKeyUnits")], duplicateKey)
    try changed("oversized-credential", ordered, [.field("records"), .index(1), .field("accessKeyUnits")],
      .array(Array(repeating: .number("97"), count: 65537)), .resourceLimit)
    let empty = try source("anonymous-empty-jar")
    try changed("empty-records", empty, [.field("records")], .array([]))
    try changed("too-many-records", empty, [.field("records")],
      .array(Array(repeating: try empty.field("records").values()[0], count: 257)), .resourceLimit)

    // Reduced limits make the resource obligation observable with real source
    // jars; each jar alone fits, while the complete account collection fails.
    for (label, change) in [("cumulative-buckets", 0), ("cumulative-cookies", 1)] {
      var limits = PiliOrderedCookieArchiveLimits.standard
      if change == 0 { limits.maximumBuckets = 2 } else { limits.maximumCookies = 4 }
      for record in try ordered.field("records").values() {
        _ = try PiliOrderedCookieArchiveCodec(limits: limits).decode(record.field("jar").wire())
        checks += 1
      }
      try failure(label, rootWire, .resourceLimit, limits: limits)
    }
    var metadata = PiliOrderedCookieArchiveLimits.standard
    metadata.maximumUTF16Units = 2559 // Anonymous record reservation is 2048+512.
    try failure("metadata-reservation", empty.wire(), .resourceLimit, limits: metadata)
    // Count the actual owned units in source JSON independently of the DTO.
    func actualUnitCount(_ node: OracleJSON) throws -> Int {
      switch node {
      case .object(let fields):
        return try fields.reduce(0) { total, field in
          if field.key.hasSuffix("Units"), case .array(let values) = field.value { return total + values.count }
          return total + (try actualUnitCount(field.value))
        }
      case .array(let values): return try values.reduce(0) { $0 + (try actualUnitCount($1)) }
      default: return 0
      }
    }
    var sharedUnits = PiliOrderedCookieArchiveLimits.standard
    sharedUnits.maximumUTF16Units = 2048 + 512 * (try ordered.field("records").values().count) + (try actualUnitCount(ordered)) - 1
    for record in try ordered.field("records").values() {
      _ = try PiliOrderedCookieArchiveCodec(limits: sharedUnits).decode(record.field("jar").wire())
      checks += 1
    }
    try failure("cumulative-jar-and-metadata-units", rootWire, .resourceLimit, limits: sharedUnits)
    for (label, kind) in [("wire-byte-limit", 0), ("whole-tree-depth", 1), ("whole-tree-nodes", 2)] {
      var limits = PiliOrderedCookieArchiveLimits.standard
      if kind == 0 { limits.maximumEncodedBytes = rootWire.count - 1 }
      else if kind == 1 { limits.maximumJSONDepth = 2 }
      else { limits.maximumJSONNodes = 4 }
      try failure(label, rootWire, .resourceLimit, limits: limits)
    }
    // Explicit synthetic representation boundary, never actual Dart clock or
    // generation evidence. Exact number tokens must survive beyond Double.
    let integerSeed = try ordered.replacing([.field("revision")], with: .number("9223372036854775807"))
    let integerEncoded = try codec.encode(codec.decode(integerSeed.wire()))
    try check(try read(integerEncoded) == integerSeed, "Synthetic Int64 token must not round")
    print("\(checks) native account envelope checks passed; actualDartObservations=\(observed) negativeCases=\(negatives) syntheticIntegerCases=1 runtimeEnabled=false")
  }
}
