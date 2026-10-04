import Foundation

private enum FixtureError: Error { case failure(String) }

@main
private struct NativeCookieFixture {
  static func main() throws {
    guard CommandLine.arguments.count == 2,
          let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any],
          let parserCases = golden["parserCases"] as? [[String: Any]],
          let selections = golden["selections"] as? [[String: Any]] else { throw FixtureError.failure("Dart export missing") }
    var checks = 0
    func check(_ condition: Bool, _ reason: String) throws {
      guard condition else { throw FixtureError.failure(reason) }; checks += 1
    }
    for item in parserCases {
      guard let raw = item["raw"] as? String, let urlString = item["url"] as? String,
            let url = URL(string: urlString), let created = item["createdSeconds"] as? Int64,
            let accepted = item["accepted"] as? Bool else { throw FixtureError.failure("invalid fixture case") }
      if accepted {
        guard let expected = item["record"] else { throw FixtureError.failure("expected Dart Cookie missing") }
        let record = try JSONDecoder().decode(PiliAccountCookieRecord.self, from: JSONSerialization.data(withJSONObject: expected))
        let native = try PiliNativeCookieParser.parse(raw, responseURL: url, createdSeconds: created, sequence: 0)
        try check(native == record, "Dart/native parsed properties mismatch: \(raw)")
      } else {
        do {
          _ = try PiliNativeCookieParser.parse(raw, responseURL: url, createdSeconds: created, sequence: 0)
          throw FixtureError.failure("Native accepted Dart-rejected field: \(raw)")
        } catch is PiliNativeCookieError { checks += 1 }
      }
    }
    let identity = PiliAccountIdentity(ownerToken: "00000000-0000-4000-8000-000000000001", generation: 1)
    for item in selections {
      guard let urlString = item["url"] as? String, let url = URL(string: urlString),
            let now = item["nowMicroseconds"] as? Int64, let ignoreExpires = item["ignoreExpires"] as? Bool,
            let expected = item["header"] as? String, let rawCookies = item["cookies"] else { throw FixtureError.failure("invalid selection case") }
      let cookies = try JSONDecoder().decode([PiliAccountCookieRecord].self, from: JSONSerialization.data(withJSONObject: rawCookies))
      let archive = PiliAccountCookieArchive(schemaVersion: 1, identity: identity, ignoreExpires: ignoreExpires,
        legacyHiveAttributesIncomplete: false, cookies: cookies)
      let header = try PiliNativeCookieSelector.compatibilityHeader(archive: archive, url: url, nowMicroseconds: now)
      try check(header == expected, "Dart/native header ordering/expiry mismatch: \(urlString) ignore=\(ignoreExpires)")
    }
    let url = URL(string: "https://api.bilibili.com/x/test")!
    do {
      _ = try PiliNativeCookieParser.parseFields(["a=1", "b=2"], representation: .foundationCombined,
        responseURL: url, createdSeconds: 1700000000)
      throw FixtureError.failure("Foundation field merging allowed")
    } catch PiliNativeCookieError.unsupportedRepresentation { checks += 1 }
    let fields = try PiliNativeCookieParser.parseFields(["same=root; Path=/", "same=nested; Path=/x"],
      representation: .separated, responseURL: url, createdSeconds: 1700000000)
    try check(fields.map(\.value) == ["root", "nested"], "separated field order retained")
    do {
      _ = try PiliNativeCookieParser.parseFields(["a=1", "b=bad,value"], representation: .separated,
        responseURL: url, createdSeconds: 1700000000)
      throw FixtureError.failure("partial invalid batch returned")
    } catch PiliNativeCookieError.invalidField { checks += 1 }
    let tooMany = try (0..<33).map { index in
      try PiliNativeCookieParser.parse("cookie_\(index)=value", responseURL: url, createdSeconds: 1700000000, sequence: index)
    }
    do {
      let archive = PiliAccountCookieArchive(schemaVersion: 1, identity: identity, ignoreExpires: true,
        legacyHiveAttributesIncomplete: false, cookies: tooMany)
      _ = try PiliNativeCookieSelector.compatibilityHeader(archive: archive, url: url, nowMicroseconds: 1700000000000000)
      throw FixtureError.failure("unproved large Dart unstable-sort ordering allowed")
    } catch PiliNativeCookieError.unsupportedOrdering { checks += 1 }
    let canonical = ["/é", "/e\u{301}"].enumerated().map { index, path in
      PiliAccountCookieRecord(name: "same", value: "value", domain: "api.bilibili.com", path: path,
        hostOnly: true, cookieDomain: nil, cookiePath: nil, secure: false, httpOnly: false,
        sameSite: nil, expiresMicroseconds: nil, maxAgeSeconds: nil, createdSeconds: 1700000000, sequence: index)
    }
    let archive = PiliAccountCookieArchive(schemaVersion: 1, identity: identity, ignoreExpires: true,
      legacyHiveAttributesIncomplete: false, cookies: canonical)
    try check(try archive.validated().cookies.count == 2, "archive keys distinguish canonical-equivalent UTF16 paths")
    do {
      _ = try PiliNativeCookieSelector.compatibilityHeader(archive: archive, url: url, nowMicroseconds: 1700000000000000)
      throw FixtureError.failure("unproved Unicode matching allowed")
    } catch PiliNativeCookieError.unsupportedRepresentation { checks += 1 }
    print("\(checks) native Cookie checks passed")
  }
}
