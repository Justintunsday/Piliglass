import Foundation

private enum OrderedCookieFixtureError: Error { case failure(String) }

@main
private struct OrderedCookieCodecFixture {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      throw OrderedCookieFixtureError.failure("Actual Dart exporter and mutation goldens are required")
    }
    var checks = 0
    let codec = PiliOrderedCookieArchiveCodec()
    func check(_ condition: Bool, _ reason: String) throws {
      guard condition else { throw OrderedCookieFixtureError.failure(reason) }; checks += 1
    }
    func failure(_ data: Data, _ expected: PiliOrderedCookieArchiveError, using candidate: PiliOrderedCookieArchiveCodec? = nil) throws {
      do {
        _ = try (candidate ?? codec).decode(data)
        throw OrderedCookieFixtureError.failure("Accepted invalid archive; expected \(expected)")
      } catch let error as PiliOrderedCookieArchiveError {
        try check(error == expected, "Wrong rejection: \(error), expected \(expected)")
      }
    }
    func fixture(_ path: String) throws -> [String: Any] {
      guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
            value["schemaVersion"] as? Int == 1, value["runtimeCutover"] as? Bool == false else {
        throw OrderedCookieFixtureError.failure("Missing actual Dart fixture envelope")
      }
      return value
    }
    func roundTrip(_ value: Any, _ id: String) throws -> PiliOrderedCookieArchive {
      let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      let archive = try codec.decode(data)
      let encoded = try codec.encode(archive)
      // Compare against the actual Dart wire independently of the DTO decoder.
      // Object field ordering is irrelevant; all bucket/entry/unit arrays retain
      // their order, and required nulls and exact integer fields remain present.
      let nativeJSON = try JSONSerialization.jsonObject(with: encoded)
      let nativeCanonical = try JSONSerialization.data(withJSONObject: nativeJSON, options: [.sortedKeys])
      try check(nativeCanonical == data, "Actual Dart jar fields/attributes/UTF16/order lost: \(id)")
      try check(try codec.decode(encoded) == archive, "Dart jar round trip: \(id)")
      return archive
    }

    let exports = try fixture(CommandLine.arguments[1])
    guard let cases = exports["cases"] as? [[String: Any]], !cases.isEmpty else {
      throw OrderedCookieFixtureError.failure("Actual exporter cases missing")
    }
    var ids = Set<String>()
    var observedEmptyOuter = false, observedEmptyPath = false, observedKeyMismatch = false
    var observedSurrogate = false, observedPriorHive = false
    for item in cases {
      guard let id = item["id"] as? String, ids.insert(id).inserted, let jar = item["jar"] else {
        throw OrderedCookieFixtureError.failure("Invalid exporter case")
      }
      let archive = try roundTrip(jar, id)
      observedPriorHive = observedPriorHive || archive.provenance.priorPersistence == .legacyHiveReopened
      for bucket in archive.domainBuckets + archive.hostBuckets {
        observedEmptyOuter = observedEmptyOuter || bucket.paths.isEmpty
        for path in bucket.paths {
          observedEmptyPath = observedEmptyPath || path.cookies.isEmpty
          for cookie in path.cookies {
            observedKeyMismatch = observedKeyMismatch || cookie.keyUnits != cookie.nameUnits
            observedSurrogate = observedSurrogate || cookie.keyUnits.units.contains(where: { (0xD800...0xDFFF).contains($0) })
          }
        }
      }
    }
    try check(observedEmptyOuter && observedEmptyPath, "Dart export must exercise actual empty outer/path maps")
    try check(observedKeyMismatch && observedSurrogate, "Dart export must exercise independent UTF16 map keys")
    try check(observedPriorHive, "Actual Hive reopen provenance missing")
    let requiredIDs: Set<String> = ["empty-jar", "empty-domain-host-path-name-maps",
      "map-key-distinct-from-cookie-name", "exact-utf16-keys-in-all-three-map-levels",
      "nil-required-attributes", "empty-cookie-domain-path-attributes", "actual-same-site-Strict",
      "actual-same-site-Lax", "actual-same-site-None", "live-production-response-with-full-attrs",
      "actual-hive-type8-reopened"]
    try check(requiredIDs.isSubset(of: ids), "Actual Dart exporter coverage missing")
    let mutations = try fixture(CommandLine.arguments[2])
    guard let trajectories = mutations["trajectories"] as? [[String: Any]], !trajectories.isEmpty else {
      throw OrderedCookieFixtureError.failure("Actual CookieJar mutation trajectories missing")
    }
    var trajectoryIDs = Set<String>(), steps = 0
    for trajectory in trajectories {
      guard let id = trajectory["id"] as? String, trajectoryIDs.insert(id).inserted,
            let values = trajectory["steps"] as? [[String: Any]], !values.isEmpty else {
        throw OrderedCookieFixtureError.failure("Invalid mutation trajectory")
      }
      for step in values {
        guard let label = step["label"] as? String, let jar = step["jar"] else {
          throw OrderedCookieFixtureError.failure("Actual trajectory jar missing")
        }
        _ = try roundTrip(jar, "\(id)/\(label)"); steps += 1
      }
    }
    try check(steps > 1, "Empty or trivial actual mutation golden")
    let requiredTrajectories: Set<String> = ["empty-buckets", "overwrite-remove-reinsert",
      "host-domain-header-order", "delete-false-true-all", "expiry-save-false", "expiry-save-true",
      "elapsed-expiry-secure-legacy", "bad-batch-all-or-nothing", "utf16-key-representation"]
    try check(requiredTrajectories.isSubset(of: trajectoryIDs), "Actual CookieJar mutation coverage missing")

    func units(_ values: [UInt16]) -> PiliCookieUTF16 { .init(units: values) }
    func entry(key: [UInt16] = [107], name: [UInt16] = [110], value: [UInt16] = [118],
               expires: Int64? = nil, maxAge: Int64? = nil, created: Int64 = 0) -> PiliOrderedCookieEntry {
      .init(keyUnits: units(key), nameUnits: units(name), valueUnits: units(value),
        cookieDomainUnits: nil, cookiePathUnits: units([]), secure: false, httpOnly: false,
        sameSite: nil, expiresMicroseconds: expires, maxAgeSeconds: maxAge, createdSeconds: created)
    }
    func archive(_ cookies: [PiliOrderedCookieEntry]) -> PiliOrderedCookieArchive {
      .init(schemaVersion: 2, ignoreExpires: false,
        provenance: .init(capture: "live", priorPersistence: .unknown,
          legacyHiveAttributesIncomplete: true, currentBucketOrderComplete: true),
        domainBuckets: [.init(keyUnits: units([]), paths: []),
          .init(keyUnits: units([233]), paths: [.init(keyUnits: units([]), cookies: [])]),
          .init(keyUnits: units([101, 769]), paths: [.init(keyUnits: units([47]), cookies: cookies)])],
        hostBuckets: [.init(keyUnits: units([0xD800]), paths: [])])
    }
    let canonical = archive([entry(key: [233]), entry(key: [101, 769]), entry(key: [0xD800]), entry(key: [0xFFFD])])
    let baseline = try codec.encode(canonical)
    let native = try codec.decode(baseline)
    try check(native == canonical, "Canonical-equivalent and unpaired-surrogate keys were merged")
    try check(native.domainBuckets[2].paths[0].cookies.map(\.keyUnits) == canonical.domainBuckets[2].paths[0].cookies.map(\.keyUnits),
      "Cookie insertion order changed")
    try check(native.domainBuckets[2].paths[0].cookies[0].cookieDomainUnits == nil &&
      native.domainBuckets[2].paths[0].cookies[0].cookiePathUnits == units([]), "Null and empty attributes merged")
    let minimal = try codec.encode(archive([entry()]))
    let text = String(decoding: minimal, as: UTF8.self)
    func change(_ old: String, _ new: String) throws -> Data {
      guard text.contains(old) else { throw OrderedCookieFixtureError.failure("Invalid fixture replacement: \(old)") }
      return Data(text.replacingOccurrences(of: old, with: new).utf8)
    }
    try failure(change("\"schemaVersion\":2", "\"schemaVersion\":2,\"schemaVersion\":2"), .duplicateKey)
    try failure(change("\"schemaVersion\":2", "\"schemaVersion\":2,\"schema\\u0056ersion\":2"), .duplicateKey)
    try failure(change("\"schemaVersion\":2", "\"schemaVersion\":1"), .unsupportedSchema)
    try failure(change("\"schemaVersion\":2", "\"schemaVersion\":2.0"), .invalidArchive)
    try failure(change("\"schemaVersion\":2", "\"schemaVersion\":2e0"), .invalidArchive)
    try failure(change("\"schemaVersion\":2", "\"schemaVersion\":02"), .malformedJSON)
    try failure(change("\"schemaVersion\":2", "\"schemaVersion\":2,\"unknown\":null"), .invalidArchive)
    try failure(change("\"sameSite\":null,", ""), .invalidArchive)
    try failure(change("\"cookieDomainUnits\":null,", ""), .invalidArchive)
    try failure(change("\"maxAgeSeconds\":null,", ""), .invalidArchive)
    try failure(change("\"httpOnly\":false", "\"httpOnly\":0"), .invalidArchive)
    try failure(change("\"sameSite\":null", "\"sameSite\":\"lax\""), .invalidArchive)
    try failure(change("\"createdSeconds\":0", "\"createdSeconds\":-1"), .invalidArchive)
    try failure(change("\"createdSeconds\":0", "\"createdSeconds\":9223372036854775808"), .invalidArchive)
    try failure(change("\"maxAgeSeconds\":null", "\"maxAgeSeconds\":-9223372036854775809"), .invalidArchive)
    try failure(change("\"keyUnits\":[107]", "\"keyUnits\":[true]"), .invalidArchive)
    try failure(change("\"keyUnits\":[107]", "\"keyUnits\":[65536]"), .invalidArchive)
    try failure(change("\"keyUnits\":[107]", "\"keyUnits\":[-1]"), .invalidArchive)
    try failure(change("\"capture\":\"live\"", "\"capture\":\"other\""), .invalidArchive)
    try failure(change("\"priorPersistence\":\"unknown\"", "\"priorPersistence\":\"guessed\""), .invalidArchive)
    try failure(change("\"currentBucketOrderComplete\":true", "\"currentBucketOrderComplete\":false"), .invalidArchive)
    try failure(Data("{\"x\":\"\u{00}\"}".utf8), .malformedJSON)
    try failure(Data([123, 34, 120, 34, 58, 34, 0xC0, 0xAF, 34, 125]), .malformedJSON)
    try failure(Data("{\"x\":\"\\uZZZZ\"}".utf8), .malformedJSON)
    try failure(Data("{\"é\":1,\"e\\u0301\":2}".utf8), .invalidArchive)
    try failure(Data("{\"\\uD800\":1,\"�\":2}".utf8), .invalidArchive)
    try failure(Data(minimal + Data(" true".utf8)), .malformedJSON)
    try failure(Data([0xEF, 0xBB, 0xBF]) + minimal, .malformedJSON)

    // Mutate DTOs through the same encode path used by the shadow store.
    func invalidDTO(_ input: PiliOrderedCookieArchive, _ expected: PiliOrderedCookieArchiveError) throws {
      do { _ = try codec.encode(input); throw OrderedCookieFixtureError.failure("Accepted invalid DTO") }
      catch let error as PiliOrderedCookieArchiveError { try check(error == expected, "DTO rejection: \(error)") }
    }
    try invalidDTO(archive([entry(), entry()]), .duplicateKey)
    let duplicateOuter = PiliOrderedCookieArchive(schemaVersion: 2, ignoreExpires: false,
      provenance: canonical.provenance, domainBuckets: [canonical.domainBuckets[0], canonical.domainBuckets[0]], hostBuckets: [])
    try invalidDTO(duplicateOuter, .duplicateKey)
    let duplicatePaths = PiliOrderedCookieBucket(keyUnits: units([104]), paths: [
      .init(keyUnits: units([47]), cookies: []), .init(keyUnits: units([47]), cookies: [])])
    try invalidDTO(.init(schemaVersion: 2, ignoreExpires: false, provenance: canonical.provenance,
      domainBuckets: [], hostBuckets: [duplicatePaths]), .duplicateKey)
    try invalidDTO(archive([entry(name: Array(repeating: 110, count: 1025))]), .resourceLimit)
    try invalidDTO(archive([entry(key: Array(repeating: 107, count: 4097))]), .resourceLimit)
    try invalidDTO(archive([entry(value: Array(repeating: 118, count: 65537))]), .resourceLimit)
    try invalidDTO(archive([entry(expires: PiliOrderedCookieArchive.maximumDateTimeMicroseconds + 1)]), .invalidArchive)
    try invalidDTO(archive([entry(expires: -PiliOrderedCookieArchive.maximumDateTimeMicroseconds - 1)]), .invalidArchive)
    for expiry in [-PiliOrderedCookieArchive.maximumDateTimeMicroseconds, PiliOrderedCookieArchive.maximumDateTimeMicroseconds] {
      let edge = archive([entry(expires: expiry, maxAge: expiry < 0 ? .min : .max, created: .max)])
      try check(try codec.decode(codec.encode(edge)) == edge, "Exact Int64 and DateTime limits rounded")
    }
    let capacity = archive([entry(key: Array(repeating: 107, count: 4096),
      name: Array(repeating: 110, count: 1024), value: Array(repeating: 118, count: 65536))])
    try check(try codec.decode(codec.encode(capacity)) == capacity, "Inclusive per-field capacity changed")
    for modifier in [
      { (limit: inout PiliOrderedCookieArchiveLimits) in limit.maximumEncodedBytes = minimal.count - 1 },
      { (limit: inout PiliOrderedCookieArchiveLimits) in limit.maximumJSONDepth = 2 },
      { (limit: inout PiliOrderedCookieArchiveLimits) in limit.maximumJSONNodes = 2 },
      { (limit: inout PiliOrderedCookieArchiveLimits) in limit.maximumUTF16Units = 1 },
      { (limit: inout PiliOrderedCookieArchiveLimits) in limit.maximumBuckets = 1 },
      { (limit: inout PiliOrderedCookieArchiveLimits) in limit.maximumCookies = 1 },
    ] {
      var limits = PiliOrderedCookieArchiveLimits.standard; modifier(&limits)
      try failure(baseline, .resourceLimit, using: .init(limits: limits))
    }
    var byteBoundary = PiliOrderedCookieArchiveLimits.standard
    byteBoundary.maximumEncodedBytes = minimal.count
    try check(try PiliOrderedCookieArchiveCodec(limits: byteBoundary).decode(minimal) == archive([entry()]),
      "Inclusive byte capacity changed")
    var unsafeLimits = PiliOrderedCookieArchiveLimits.standard
    unsafeLimits.maximumJSONDepth = 33
    try failure(minimal, .resourceLimit, using: .init(limits: unsafeLimits))
    try failure(Data((String(repeating: "[", count: 33) + "null" + String(repeating: "]", count: 33)).utf8), .resourceLimit)
    print("\(checks) native ordered Cookie codec checks passed; \(cases.count) actual Dart exports, \(steps) mutation snapshots")
  }
}
