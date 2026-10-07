import Foundation

/// Strict bounded codec for the complete capture-local account shadow. It
/// grants no storage, account or network authority. The entire envelope is
/// parsed exactly once by the shared strict parser; a resource-only preflight
/// runs before the first record DTO allocation, and the Domain DTO validates
/// all remaining semantics with one cumulative ledger.
struct PiliAccountLiveMemoryShadowCodec: Sendable {
  var limits: PiliOrderedCookieArchiveLimits = .standard
  private typealias Value = OrderedCookieJSONValue
  private static let recordKeys: Set<String> = [
    "record", "generation", "storageKeyUnits", "mid", "isLogin", "accessKeyUnits",
    "refreshTokenUnits", "persistedPurposes", "activated", "jar"
  ]

  func decode(_ data: Data) throws -> PiliAccountLiveMemoryShadow {
    do {
      let limits = try limits.validated()
      guard data.count <= limits.maximumEncodedBytes else {
        throw PiliAccountLiveMemoryShadowError.resourceLimit
      }
      // Parse the entire envelope exactly once. Resource preflight and Domain
      // validation below are separate passes over that bounded tree / DTO.
      var parser = OrderedCookieJSONParser(bytes: Array(data), limits: limits)
      let codec = PiliOrderedCookieArchiveCodec(limits: limits)
      let fields = try codec.object(parser.parse(), keys: [
        "schemaVersion", "scope", "identityScope", "revision", "durableIdentityConfigured",
        "durabilityVerified", "authoritySwitchAllowed", "nativeWritesAllowed", "records",
        "storedOrder", "ownerOrder", "selectionPurposes", "selections", "history"
      ])
      guard try codec.integer(fields["schemaVersion"]) == 2 else {
        throw PiliAccountLiveMemoryShadowError.unsupportedSchema
      }
      let rawRecords = try codec.array(fields["records"])
      guard !rawRecords.isEmpty else { throw PiliAccountLiveMemoryShadowError.invalidEnvelope }
      guard rawRecords.count <= 256 else {
        throw PiliAccountLiveMemoryShadowError.resourceLimit
      }
      // Reject fixed policy/type/shape errors before projecting any record DTO.
      // Compare raw parsed units before ascii() can allocate a policy String.
      try requirePolicyString(fields["scope"], equals: "coherentLiveMemoryShadow", codec: codec)
      try requirePolicyString(fields["identityScope"], equals: "captureLocal", codec: codec)
      let revision = try codec.integer(fields["revision"])
      let durableIdentityConfigured = try codec.boolean(fields["durableIdentityConfigured"])
      let durabilityVerified = try codec.boolean(fields["durabilityVerified"])
      let authoritySwitchAllowed = try codec.boolean(fields["authoritySwitchAllowed"])
      let nativeWritesAllowed = try codec.boolean(fields["nativeWritesAllowed"])
      let rawSelections = try codec.array(fields["selections"])
      guard revision >= 0, !durableIdentityConfigured, !durabilityVerified,
            !authoritySwitchAllowed, !nativeWritesAllowed, rawSelections.count == 4 else {
        throw PiliAccountLiveMemoryShadowError.invalidEnvelope
      }
      // The parser has bounded its tree allocations. Before allocating any
      // DTO unit/record/bucket arrays, independently bound projection resources.
      try preflight(fields, records: rawRecords, codec: codec)
      let records = try rawRecords.map { value in
        let record = try codec.object(value, keys: Self.recordKeys)
        return try PiliAccountLiveMemoryRecord(
          record: index(record["record"], codec: codec),
          generation: codec.integer(record["generation"]),
          storageKeyUnits: codec.optionalUnits(record["storageKeyUnits"]),
          mid: codec.integer(record["mid"]), isLogin: codec.boolean(record["isLogin"]),
          accessKeyUnits: codec.optionalUnits(record["accessKeyUnits"]),
          refreshTokenUnits: codec.optionalUnits(record["refreshTokenUnits"]),
          persistedPurposes: purposes(record["persistedPurposes"], codec: codec),
          activated: codec.boolean(record["activated"]),
          jar: codec.decodeValue(codec.required(record["jar"]))
        )
      }
      let result = try PiliAccountLiveMemoryShadow(
        schemaVersion: 2, scope: codec.ascii(fields["scope"]),
        identityScope: codec.ascii(fields["identityScope"]), revision: revision,
        durableIdentityConfigured: durableIdentityConfigured,
        durabilityVerified: durabilityVerified,
        authoritySwitchAllowed: authoritySwitchAllowed,
        nativeWritesAllowed: nativeWritesAllowed, records: records,
        storedOrder: order(fields["storedOrder"], codec: codec),
        ownerOrder: order(fields["ownerOrder"], codec: codec),
        selectionPurposes: purposes(fields["selectionPurposes"], codec: codec),
        selections: rawSelections.map { try index($0, codec: codec) },
        history: index(fields["history"], codec: codec)
      )
      return try result.validated(limits: limits)
    } catch let error as PiliOrderedCookieArchiveError {
      // Preserve the old jar error contract; only this independent envelope
      // boundary translates nested/parser errors to its own error enum.
      switch error {
      case .malformedJSON: throw PiliAccountLiveMemoryShadowError.malformedJSON
      case .duplicateKey: throw PiliAccountLiveMemoryShadowError.duplicateKey
      case .resourceLimit: throw PiliAccountLiveMemoryShadowError.resourceLimit
      case .invalidArchive, .unsupportedSchema: throw PiliAccountLiveMemoryShadowError.invalidEnvelope
      }
    }
  }

  func encode(_ candidate: PiliAccountLiveMemoryShadow) throws -> Data {
    let candidate = try candidate.validated(limits: limits)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(candidate)
    _ = try decode(data)
    return data
  }

  private func requirePolicyString(_ value: Value?, equals expected: String,
                                   codec: PiliOrderedCookieArchiveCodec) throws {
    guard case .string(let text) = try codec.required(value),
          text.units.elementsEqual(expected.utf16) else {
      throw PiliAccountLiveMemoryShadowError.invalidEnvelope
    }
  }

  /// Resource-only pass over the parsed tree. No UTF16 DTO, Cookie semantics,
  /// byte re-encoding, parser restart or per-account budget reset occurs here.
  /// Domain later uses a separate ledger to validate constructed DTOs as well.
  private func preflight(_ fields: [String: Value], records: [Value],
                         codec: PiliOrderedCookieArchiveCodec) throws {
    let limits = codec.limits
    var budget = try PiliOrderedCookieArchiveBudget(limits: limits)
    try budget.reserveUnits(2048 + 512 * records.count)
    for value in records {
      // object() first requires exact ASCII field-key code units. Thus these
      // fixed *Units lookups cannot merge Unicode-canonical equivalent names.
      let record = try codec.object(value, keys: Self.recordKeys)
      try countUnits(record["storageKeyUnits"], maximum: limits.maximumBucketKeyUnits,
                     nullable: true, codec: codec, budget: &budget)
      for name in ["accessKeyUnits", "refreshTokenUnits"] {
        try countUnits(record[name], maximum: limits.maximumValueUnits,
                       nullable: true, codec: codec, budget: &budget)
      }
      let jar = try codec.object(codec.required(record["jar"]), keys: PiliOrderedCookieArchiveCodec.archiveKeys)
      for name in ["domainBuckets", "hostBuckets"] {
        let buckets = try codec.array(jar[name])
        try budget.addBuckets(buckets.count)
        for value in buckets {
          let bucket = try codec.object(value, keys: PiliOrderedCookieArchiveCodec.bucketKeys)
          try countUnits(bucket["keyUnits"], maximum: limits.maximumBucketKeyUnits,
                         codec: codec, budget: &budget)
          let paths = try codec.array(bucket["paths"])
          try budget.addBuckets(paths.count)
          for value in paths {
            let path = try codec.object(value, keys: PiliOrderedCookieArchiveCodec.pathKeys)
            try countUnits(path["keyUnits"], maximum: limits.maximumBucketKeyUnits,
                           codec: codec, budget: &budget)
            let cookies = try codec.array(path["cookies"])
            try budget.addCookies(cookies.count)
            for value in cookies {
              let cookie = try codec.object(value, keys: PiliOrderedCookieArchiveCodec.cookieKeys)
              try countUnits(cookie["keyUnits"], maximum: limits.maximumBucketKeyUnits,
                             codec: codec, budget: &budget)
              try countUnits(cookie["nameUnits"], maximum: limits.maximumNameUnits,
                             codec: codec, budget: &budget)
              try countUnits(cookie["valueUnits"], maximum: limits.maximumValueUnits,
                             codec: codec, budget: &budget)
              for name in ["cookieDomainUnits", "cookiePathUnits"] {
                try countUnits(cookie[name], maximum: limits.maximumBucketKeyUnits,
                               nullable: true, codec: codec, budget: &budget)
              }
            }
          }
        }
      }
    }
    for name in ["storedOrder", "ownerOrder"] {
      let entries = try codec.array(fields[name])
      guard entries.count <= 255 else { throw PiliAccountLiveMemoryShadowError.resourceLimit }
      for value in entries {
        let entry = try codec.object(value, keys: ["keyUnits", "record"])
        try countUnits(entry["keyUnits"], maximum: limits.maximumBucketKeyUnits,
                       codec: codec, budget: &budget)
      }
    }
  }

  private func countUnits(_ value: Value?, maximum: Int, nullable: Bool = false,
                          codec: PiliOrderedCookieArchiveCodec,
                          budget: inout PiliOrderedCookieArchiveBudget) throws {
    if nullable, case .null = try codec.required(value) { return }
    // Counting the existing array length makes no UInt16 allocation. Unit
    // element integer/range validation remains with the existing projection.
    try budget.countUnits(codec.array(value).count, maximum: maximum)
  }

  private func index(_ value: OrderedCookieJSONValue?, codec: PiliOrderedCookieArchiveCodec) throws -> Int {
    guard let result = Int(exactly: try codec.integer(value)) else {
      throw PiliAccountLiveMemoryShadowError.invalidEnvelope
    }
    return result
  }

  private func purposes(_ value: OrderedCookieJSONValue?, codec: PiliOrderedCookieArchiveCodec) throws
    -> [PiliAccountPurpose] {
    let values = try codec.array(value)
    guard values.count <= 4 else { throw PiliAccountLiveMemoryShadowError.invalidEnvelope }
    return try values.map { value in
      // Fixed enum literals can be compared in the parsed tree without first
      // allocating an arbitrarily long invalid ASCII purpose String.
      guard case .string(let text) = try codec.required(value),
            let purpose = PiliAccountPurpose.allCases.first(where: {
              $0.rawValue.utf16.elementsEqual(text.units)
            }) else {
        throw PiliAccountLiveMemoryShadowError.invalidEnvelope
      }
      return purpose
    }
  }

  private func order(_ value: OrderedCookieJSONValue?, codec: PiliOrderedCookieArchiveCodec) throws
    -> [PiliAccountLiveMemoryOrderEntry] {
    let values = try codec.array(value)
    guard values.count <= 255 else { throw PiliAccountLiveMemoryShadowError.resourceLimit }
    return try values.map { value in
      let fields = try codec.object(value, keys: ["keyUnits", "record"])
      return try PiliAccountLiveMemoryOrderEntry(keyUnits: codec.units(fields["keyUnits"]),
                                                record: index(fields["record"], codec: codec))
    }
  }
}
