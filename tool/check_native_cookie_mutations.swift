import Foundation

private enum MutationFixtureError: Error { case failure(String), clockAmbiguous(String) }
private enum ExpectedMutationRejection {
  case mutation(PiliOrderedCookieMutationError)
  case cookie(PiliNativeCookieError)
  case archive(PiliOrderedCookieArchiveError)
}
private struct CookieAddress: Hashable {
  let hostOnly: Bool
  let outer: PiliCookieUTF16
  let path: PiliCookieUTF16
  let name: PiliCookieUTF16
}

@main
private struct NativeCookieMutationFixture {
  static func main() throws {
    guard CommandLine.arguments.count == 2,
      let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
        URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any],
      fixture["schemaVersion"] as? Int == 1, fixture["runtimeCutover"] as? Bool == false,
      let clock = fixture["clockPolicy"] as? [String: Any],
      clock["kind"] as? String == "actualDartDateTimeNow", clock["injectedClock"] as? Bool == false,
      clock["exactBoundaryProof"] as? Bool == false,
      let trajectories = fixture["trajectories"] as? [[String: Any]] else {
      throw MutationFixtureError.failure("Actual Dart mutation trajectories and real clock windows required")
    }
    let codec = PiliOrderedCookieArchiveCodec(), reducer = PiliNativeOrderedCookieReducer()
    var checks = 0, stepCount = 0, headerCount = 0
    func check(_ condition: Bool, _ reason: String) throws {
      guard condition else { throw MutationFixtureError.failure(reason) }; checks += 1
    }
    func units(_ value: String) -> PiliCookieUTF16 { .init(units: Array(value.utf16)) }
    func json(_ archive: PiliOrderedCookieArchive) throws -> Any {
      try JSONSerialization.jsonObject(with: codec.encode(archive))
    }
    func canonical(_ value: Any) throws -> Data {
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func omitCreation(_ value: Any) -> Any {
      if let list = value as? [Any] { return list.map(omitCreation) }
      if var object = value as? [String: Any] {
        for (key, value) in object {
          object[key] = key == "createdSeconds" ? 0 : omitCreation(value)
        }
        return object
      }
      return value
    }
    func entries(_ jar: PiliOrderedCookieArchive) -> [CookieAddress: PiliOrderedCookieEntry] {
      var result = [CookieAddress: PiliOrderedCookieEntry]()
      for (hostOnly, group) in [(false, jar.domainBuckets), (true, jar.hostBuckets)] {
        for bucket in group { for path in bucket.paths { for entry in path.cookies {
          result[.init(hostOnly: hostOnly, outer: bucket.keyUnits, path: path.keyUnits, name: entry.keyUnits)] = entry
        } } }
      }
      return result
    }
    func empty(_ ignore: Bool) -> PiliOrderedCookieArchive {
      .init(schemaVersion: 2, ignoreExpires: ignore,
        provenance: .init(capture: "live", priorPersistence: .unknown,
          legacyHiveAttributesIncomplete: true, currentBucketOrderComplete: true),
        domainBuckets: [], hostBuckets: [])
    }
    func changed(_ jar: PiliOrderedCookieArchive, domains: [PiliOrderedCookieBucket],
      hosts: [PiliOrderedCookieBucket]) -> PiliOrderedCookieArchive {
      .init(schemaVersion: jar.schemaVersion, ignoreExpires: jar.ignoreExpires,
        provenance: jar.provenance, domainBuckets: domains, hostBuckets: hosts)
    }
    func location(_ text: String) throws -> PiliOrderedCookieResponseLocation {
      // Fixture URLs are explicitly ASCII and unescaped. Reject rather than
      // claiming Foundation percent/Unicode canonicalization equals Dart Uri.
      guard text.utf16.allSatisfy({ $0 < 128 }), !text.contains("%"),
        let components = URLComponents(string: text),
        ["http", "https"].contains(components.scheme ?? ""),
        components.user == nil, components.password == nil else {
        throw MutationFixtureError.failure("Unsupported fixture URI")
      }
      return .init(host: components.host ?? "", path: components.path)
    }
    func syntheticEntry(_ key: PiliCookieUTF16, _ value: String, _ now: Int64) -> PiliOrderedCookieEntry {
      .init(keyUnits: key, nameUnits: units("synthetic"), valueUnits: units(value),
        cookieDomainUnits: nil, cookiePathUnits: nil, secure: false, httpOnly: false,
        sameSite: nil, expiresMicroseconds: nil, maxAgeSeconds: nil, createdSeconds: now / 1_000_000)
    }
    func fieldAddresses(_ fields: [String], _ context: PiliOrderedCookieResponseLocation,
      _ now: Int64) throws -> Set<CookieAddress> {
      let parsed = try PiliNativeCookieParser.parseFields(fields, representation: .separated,
        responseURL: URL(string: "https://fixture.invalid/")!, createdSeconds: now / 1_000_000)
      return Set(parsed.map { cookie in
        let domain = cookie.cookieDomain.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
        let path = cookie.cookiePath ?? (domain != nil || context.path.isEmpty ? "/" :
          context.path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/"))
        return .init(hostOnly: domain == nil, outer: units(domain ?? context.host),
          path: units(path), name: units(cookie.name))
      })
    }
    var ids = Set<String>()
    let required: Set<String> = ["empty-buckets", "overwrite-remove-reinsert", "host-domain-header-order",
      "delete-false-true-all", "expiry-save-false", "expiry-save-true", "elapsed-expiry-secure-legacy",
      "bad-batch-all-or-nothing", "utf16-key-representation"]
    for trajectory in trajectories {
      guard let id = trajectory["id"] as? String, ids.insert(id).inserted,
        let steps = trajectory["steps"] as? [[String: Any]], !steps.isEmpty else {
        throw MutationFixtureError.failure("Missing actual trajectory")
      }
      var jar = empty(id == "expiry-save-true"), previousDart = jar
      for step in steps {
        guard let label = step["label"] as? String, let operation = step["operation"] as? [String: Any],
          let kind = operation["kind"] as? String, let expectedJSON = step["jar"],
          let outcome = step["outcome"] as? String,
          ["applied", "rejectedBeforeMutation"].contains(outcome),
          let started = (step["startedMicroseconds"] as? NSNumber)?.int64Value,
          let finished = (step["finishedMicroseconds"] as? NSNumber)?.int64Value,
          started >= 0, finished >= started,
          finished <= PiliOrderedCookieArchive.maximumDateTimeMicroseconds else {
          throw MutationFixtureError.failure("Missing actual operation/clock evidence")
        }
        let reason = "\(id)/\(label)", before = jar
        let createsCookies = ["saveFromSeparatedResponseFields", "seedPublicUTF16Maps",
          "seedPublicUTF16Overwrite"].contains(kind)
        // The real producer's clock is not injectable. A single Native clock
        // can only prove creation semantics when this measured successful
        // operation remains in one second. Crossed evidence fails explicitly;
        // endpoints cannot prove mixed per-cookie construction times.
        if createsCookies && outcome == "applied" && started / 1_000_000 != finished / 1_000_000 {
          throw MutationFixtureError.clockAmbiguous(reason)
        }
        // One explicit operation clock, independently chosen from its real
        // observed window. Expected jar creation fields never drive mutation.
        let now = started
        var touched = Set<CookieAddress>(), didReject = false
        do {
          switch kind {
          case "capture", "waitRealWallTime": break
          case "saveFromSeparatedResponseFields":
            guard let url = operation["url"] as? String, let fields = operation["fields"] as? [String],
              operation["source"] as? String == "separatedFields" else {
              throw MutationFixtureError.failure("Missing separated response operation")
            }
            let context = try location(url)
            jar = try reducer.save(jar, fields: fields, representation: .separated,
              location: context, nowMicroseconds: now)
            touched = try fieldAddresses(fields, context, now)
          case "delete":
            guard let url = operation["url"] as? String,
              let shared = operation["withDomainSharedCookie"] as? Bool else {
              throw MutationFixtureError.failure("Missing delete operation")
            }
            jar = try reducer.delete(jar, host: location(url).host, withDomainSharedCookie: shared)
          case "deleteAll": jar = try reducer.deleteAll(jar)
          case "seedPublicEmptyBuckets":
            guard let domain = operation["domainKeyUnits"] as? [UInt16],
              let host = operation["hostKeyUnits"] as? [UInt16] else {
              throw MutationFixtureError.failure("Missing empty public map seed")
            }
            jar = changed(jar, domains: jar.domainBuckets + [.init(keyUnits: .init(units: domain), paths: [])],
              hosts: jar.hostBuckets + [.init(keyUnits: .init(units: host), paths: [])])
          case "seedPublicUTF16Maps":
            guard let keys = operation["keys"] as? [[UInt16]],
              operation["requestHeaderSupported"] as? Bool == false else {
              throw MutationFixtureError.failure("Missing representation-only UTF16 seed")
            }
            var domains = jar.domainBuckets, hosts = jar.hostBuckets
            for (index, raw) in keys.enumerated() {
              let key = PiliCookieUTF16(units: raw)
              domains.append(.init(keyUnits: key, paths: [
                .init(keyUnits: key, cookies: [syntheticEntry(key, "value-\(index)", now)]),
                .init(keyUnits: units("empty-name-map"), cookies: [])]))
              hosts.append(.init(keyUnits: key, paths: []))
              touched.insert(.init(hostOnly: false, outer: key, path: key, name: key))
            }
            jar = changed(jar, domains: domains, hosts: hosts)
          case "seedPublicUTF16Overwrite", "removePublicDomainBucket", "reinsertPublicDomainBucket":
            guard let raw = operation["keyUnits"] as? [UInt16] else {
              throw MutationFixtureError.failure("Missing public map operation key")
            }
            let key = PiliCookieUTF16(units: raw)
            var domains = jar.domainBuckets
            if kind == "removePublicDomainBucket" { domains.removeAll { $0.keyUnits == key } }
            else if kind == "reinsertPublicDomainBucket" { domains.append(.init(keyUnits: key, paths: [])) }
            else {
              guard let outer = domains.firstIndex(where: { $0.keyUnits == key }),
                let path = domains[outer].paths.firstIndex(where: { $0.keyUnits == key }),
                let name = domains[outer].paths[path].cookies.firstIndex(where: { $0.keyUnits == key }) else {
                throw MutationFixtureError.failure("Missing independently seeded public key")
              }
              var paths = domains[outer].paths, cookies = paths[path].cookies
              cookies[name] = syntheticEntry(key, "replacement", now)
              paths[path] = .init(keyUnits: key, cookies: cookies)
              domains[outer] = .init(keyUnits: key, paths: paths)
              touched.insert(.init(hostOnly: false, outer: key, path: key, name: key))
            }
            jar = changed(jar, domains: domains, hosts: jar.hostBuckets)
          default: throw MutationFixtureError.failure("Unknown actual operation: \(kind)")
          }
        } catch let error as MutationFixtureError { throw error }
        catch let error as PiliNativeCookieError {
          // The actual negative trajectory contains malformed name fields.
          // A resource, location, date, or provenance error cannot substitute
          // for the expected production parser rejection.
          guard error == .invalidField else {
            throw MutationFixtureError.failure("Wrong actual batch rejection: \(reason)/\(error)")
          }
          didReject = true
        } catch { throw MutationFixtureError.failure("Unexpected mutation error: \(reason)/\(error)") }
        try check(didReject == (outcome == "rejectedBeforeMutation"), "Rejection outcome differs: \(reason)")
        if didReject { try check(jar == before, "Rejected batch changed input: \(reason)") }
        _ = try codec.encode(jar)
        let expected = try codec.decode(canonical(expectedJSON))
        try check(try canonical(omitCreation(json(jar))) == canonical(omitCreation(expectedJSON)),
          "Actual Dart non-clock fields or insertion order differ: \(reason)")
        let actualEntries = entries(jar), expectedEntries = entries(expected)
        let beforeEntries = entries(before), previousDartEntries = entries(previousDart)
        for (address, entry) in actualEntries {
          guard let dartEntry = expectedEntries[address] else {
            throw MutationFixtureError.failure("Dart entry missing: \(reason)")
          }
          if touched.contains(address) {
            try check(entry.createdSeconds == now / 1_000_000,
              "Native creation did not use injected clock: \(reason)")
            try check(dartEntry.createdSeconds >= started / 1_000_000 &&
              dartEntry.createdSeconds <= finished / 1_000_000,
              "Actual Dart creation outside actual operation window: \(reason)")
          } else {
            try check(beforeEntries[address]?.createdSeconds == entry.createdSeconds &&
              previousDartEntries[address]?.createdSeconds == dartEntry.createdSeconds,
              "Untouched creation changed: \(reason)")
          }
        }
        guard let requests = step["requests"] as? [[String: Any]],
          (id == "utf16-key-representation" ? requests.isEmpty : !requests.isEmpty) else {
          throw MutationFixtureError.failure("Actual header observations missing")
        }
        for observation in requests {
          guard let text = observation["url"] as? String, let url = URL(string: text),
            let header = observation["header"] as? String,
            let loadClock = (observation["startedMicroseconds"] as? NSNumber)?.int64Value,
            let loadFinished = (observation["finishedMicroseconds"] as? NSNumber)?.int64Value,
            loadClock >= 0, loadFinished >= loadClock,
            loadFinished <= PiliOrderedCookieArchive.maximumDateTimeMicroseconds else {
            throw MutationFixtureError.failure("Missing actual load clock/header")
          }
          // All fields in an observed load must share one measured second;
          // otherwise Max-Age checks may see mixed clocks during traversal.
          guard loadClock / 1_000_000 == loadFinished / 1_000_000 else {
            throw MutationFixtureError.clockAmbiguous("\(reason)/load/\(text)")
          }
          let nativeHeader = try PiliNativeCookieSelector.compatibilityHeader(
            archive: flatArchive(jar), url: url, nowMicroseconds: loadClock)
          try check(nativeHeader == header, "Actual Dart header differs: \(reason)/\(text)")
          headerCount += 1
        }
        previousDart = expected; stepCount += 1
      }
    }
    try check(ids == required && stepCount >= 34 && headerCount >= 43,
      "Actual mutation operation/header coverage missing")
    let baseline = empty(false), context = PiliOrderedCookieResponseLocation(host: "api.bilibili.com", path: "/x/test")
    func rejects(_ expected: ExpectedMutationRejection,
      _ action: () throws -> PiliOrderedCookieArchive, _ reason: String) throws {
      do { _ = try action(); throw MutationFixtureError.failure("Accepted invalid \(reason)") }
      catch let error as MutationFixtureError { throw error }
      catch {
        let matches: Bool
        switch expected {
        case .mutation(let required): matches = (error as? PiliOrderedCookieMutationError) == required
        case .cookie(let required): matches = (error as? PiliNativeCookieError) == required
        case .archive(let required): matches = (error as? PiliOrderedCookieArchiveError) == required
        }
        try check(matches, "Wrong rejection for \(reason): \(error)")
      }
    }
    for now in [Int64(-1), PiliOrderedCookieArchive.maximumDateTimeMicroseconds + 1] {
      try rejects(.mutation(.invalidClock), { try reducer.save(baseline, fields: ["a=b"], representation: .separated,
        location: context, nowMicroseconds: now) }, "clock")
    }
    for representation in [PiliNativeCookieFieldRepresentation.foundationCombined, .unsupported] {
      try rejects(.cookie(.unsupportedRepresentation), { try reducer.save(baseline, fields: ["a=b"], representation: representation,
        location: context, nowMicroseconds: 0) }, "field provenance")
    }
    try rejects(.cookie(.invalidField), { try reducer.save(baseline, fields: ["a=b", "bad name=value"], representation: .separated,
      location: context, nowMicroseconds: 0) }, "invalid batch")
    try rejects(.mutation(.unsupportedField), { try reducer.save(baseline, fields: ["a=b; Domain=é"], representation: .separated,
      location: context, nowMicroseconds: 0) }, "Unicode field scope")
    try rejects(.mutation(.unsupportedLocation), { try reducer.save(baseline, fields: ["a=b"], representation: .separated,
      location: .init(host: "é", path: "/"), nowMicroseconds: 0) }, "Unicode URI scope")
    var small = PiliOrderedCookieArchiveLimits.standard; small.maximumCookies = 1
    let bounded = PiliNativeOrderedCookieReducer(limits: small)
    try rejects(.archive(.resourceLimit), { try bounded.save(baseline, fields: ["a=b", "c=d"], representation: .separated,
      location: context, nowMicroseconds: 0) }, "complete result resource limit")
    try rejects(.mutation(.batchResourceLimit), { try reducer.save(baseline,
      fields: Array(repeating: "a=b", count: 4097), representation: .separated,
      location: context, nowMicroseconds: 0) }, "whole batch count limit")
    var byteLimit = PiliOrderedCookieArchiveLimits.standard
    byteLimit.maximumEncodedBytes = try codec.encode(baseline).count + 1
    let byteBounded = PiliNativeOrderedCookieReducer(limits: byteLimit)
    try rejects(.mutation(.batchResourceLimit), { try byteBounded.save(baseline,
      fields: ["a=" + String(repeating: "b", count: byteLimit.maximumEncodedBytes)],
      representation: .separated, location: context, nowMicroseconds: 0) }, "whole batch byte limit")
    try rejects(.archive(.resourceLimit), { try byteBounded.save(baseline, fields: ["a=b"],
      representation: .separated, location: context, nowMicroseconds: 0) }, "complete result byte limit")
    let edge = try reducer.save(baseline, fields: ["a=b; Max-Age=9223372036854775807"],
      representation: .separated, location: context,
      nowMicroseconds: PiliOrderedCookieArchive.maximumDateTimeMicroseconds)
    try check(edge.hostBuckets[0].paths[0].cookies[0].createdSeconds ==
      PiliOrderedCookieArchive.maximumDateTimeMicroseconds / 1_000_000,
      "Inclusive explicitly injected DateTime edge failed")
    print("\(checks) native ordered Cookie mutation checks passed; \(stepCount) actual Dart operations, \(headerCount) actual headers; runtime disabled")
  }

  private static func flatArchive(_ jar: PiliOrderedCookieArchive) throws -> PiliAccountCookieArchive {
    var cookies = [PiliAccountCookieRecord]()
    func string(_ value: PiliCookieUTF16) throws -> String {
      guard value.units.allSatisfy({ $0 < 128 }) else {
        throw PiliNativeCookieError.unsupportedRepresentation
      }
      return String(decoding: value.units, as: UTF16.self)
    }
    for (hostOnly, group) in [(false, jar.domainBuckets), (true, jar.hostBuckets)] {
      for bucket in group { for path in bucket.paths { for entry in path.cookies {
        cookies.append(.init(name: try string(entry.nameUnits), value: try string(entry.valueUnits),
          domain: try string(bucket.keyUnits), path: try string(path.keyUnits), hostOnly: hostOnly,
          cookieDomain: try entry.cookieDomainUnits.map(string), cookiePath: try entry.cookiePathUnits.map(string),
          secure: entry.secure, httpOnly: entry.httpOnly, sameSite: entry.sameSite?.rawValue,
          expiresMicroseconds: entry.expiresMicroseconds, maxAgeSeconds: entry.maxAgeSeconds,
          createdSeconds: entry.createdSeconds, sequence: cookies.count))
      } } }
    }
    return .init(schemaVersion: 1,
      identity: .init(ownerToken: "00000000-0000-0000-0000-000000000001", generation: 1),
      ignoreExpires: jar.ignoreExpires, legacyHiveAttributesIncomplete: true, cookies: cookies)
  }
}
