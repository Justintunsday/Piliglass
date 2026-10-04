import Foundation

enum PiliNativeCookieError: Error, Sendable, Equatable {
  case invalidField, invalidDate, unsupportedOrdering, unsupportedRepresentation
}

enum PiliNativeCookieFieldRepresentation: Sendable, Equatable {
  case separated, foundationCombined, unsupported
}

/// Pure compatibility parser for the pinned Dart Cookie contract. Response
/// field separation is a transport responsibility, never inferred here.
enum PiliNativeCookieParser {
  static func parseFields(_ fields: [String], representation: PiliNativeCookieFieldRepresentation,
    responseURL: URL, createdSeconds: Int64) throws -> [PiliAccountCookieRecord] {
    guard representation == .separated else { throw PiliNativeCookieError.unsupportedRepresentation }
    guard fields.count <= 4096 else { throw PiliNativeCookieError.invalidField }
    // Complete parsing precedes any caller mutation; one bad field rejects the batch.
    return try fields.enumerated().map { index, field in
      try parse(field, responseURL: responseURL, createdSeconds: createdSeconds, sequence: index)
    }
  }

  static func parse(_ source: String, responseURL: URL, createdSeconds: Int64, sequence: Int) throws -> PiliAccountCookieRecord {
    guard source.utf8.count <= 65536, createdSeconds >= 0 else { throw PiliNativeCookieError.invalidField }
    let units = Array(source.utf16)
    var index = 0
    func whitespace(_ value: UInt16) -> Bool { value == 32 || value == 9 }
    func skip() { while index < units.count && whitespace(units[index]) { index += 1 } }
    func scan(until delimiter: UInt16) -> Int {
      var end = index
      while index < units.count {
        let value = units[index]; index += 1
        if value == delimiter { break }
        if !whitespace(value) { end = index }
      }
      return end
    }
    func string(_ start: Int, _ end: Int) -> String { String(decoding: units[start..<end], as: UTF16.self) }
    skip()
    let nameStart = index
    let nameEnd = scan(until: 61)
    // Dart's parser distinguishes a= from a=; and a= followed by whitespace.
    guard index < units.count, nameEnd > nameStart else { throw PiliNativeCookieError.invalidField }
    let name = string(nameStart, nameEnd)
    let separators = Set("()<>@,;:\\\"/[]?={}".utf16)
    guard name.utf16.allSatisfy({ $0 > 32 && $0 < 127 && !separators.contains($0) }) else {
      throw PiliNativeCookieError.invalidField
    }
    skip()
    let valueStart = index
    let valueEnd = scan(until: 59)
    let value = string(valueStart, valueEnd)
    var checkedValue = Array(value.utf16)
    if checkedValue.count >= 2 && checkedValue.first == 34 && checkedValue.last == 34 {
      checkedValue.removeFirst(); checkedValue.removeLast()
    }
    guard checkedValue.allSatisfy({ (33...126).contains($0) && ![34, 44, 59, 92].contains($0) }) else {
      throw PiliNativeCookieError.invalidField
    }
    var domain: String?
    var path: String?
    var secure = false
    var httpOnly = false
    var sameSite: String?
    var expires: Int64?
    var maxAge: Int64?
    while index < units.count {
      skip()
      if index == units.count { break }
      let start = index
      var end = index
      var delimiter: UInt16 = 0
      repeat {
        delimiter = units[index]; index += 1
        if delimiter == 61 || delimiter == 59 { break }
        if !whitespace(delimiter) { end = index }
      } while index < units.count
      let attribute = string(start, end).lowercased()
      var attributeValue: String?
      if delimiter == 61 {
        skip(); let start = index; let end = scan(until: 59)
        attributeValue = string(start, end)
      }
      switch attribute {
      case "domain": domain = attributeValue ?? ""
      case "path":
        let value = attributeValue ?? ""
        guard value.utf16.allSatisfy({ $0 >= 32 && $0 < 127 && $0 != 59 }) else { throw PiliNativeCookieError.invalidField }
        path = value
      case "secure":
        guard attributeValue == nil else { throw PiliNativeCookieError.invalidField }; secure = true
      case "httponly":
        guard attributeValue == nil else { throw PiliNativeCookieError.invalidField }; httpOnly = true
      case "samesite":
        guard let value = attributeValue?.lowercased(), ["lax", "strict", "none"].contains(value) else { throw PiliNativeCookieError.invalidField }
        sameSite = value
      case "expires":
        guard let value = attributeValue else { throw PiliNativeCookieError.invalidField }; expires = try cookieDate(value)
      case "max-age":
        guard let value = attributeValue, let parsed = integer(value) else { throw PiliNativeCookieError.invalidField }; maxAge = parsed
      default: break
      }
    }
    guard sameSite != "none" || secure, let host = responseURL.host else { throw PiliNativeCookieError.invalidField }
    let hostOnly = domain == nil
    let bucketDomain = domain.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 } ?? host
    let bucketPath: String
    if let path { bucketPath = path }
    else if !hostOnly { bucketPath = "/" }
    else {
      let current = responseURL.path
      bucketPath = current.isEmpty ? "/" : current.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
    }
    return PiliAccountCookieRecord(name: name, value: value, domain: bucketDomain, path: bucketPath,
      hostOnly: hostOnly, cookieDomain: domain, cookiePath: path, secure: secure, httpOnly: httpOnly,
      sameSite: sameSite, expiresMicroseconds: expires, maxAgeSeconds: maxAge, createdSeconds: createdSeconds, sequence: sequence)
  }

  private static func integer(_ value: String) -> Int64? {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    var negative = false
    if text.hasPrefix("-") { negative = true; text.removeFirst() }
    else if text.hasPrefix("+") { text.removeFirst() }
    if text.lowercased().hasPrefix("0x") {
      text.removeFirst(2)
      guard !text.isEmpty, let magnitude = UInt64(text, radix: 16) else { return nil }
      if negative {
        if magnitude == UInt64(Int64.max) + 1 { return .min }
        guard magnitude <= UInt64(Int64.max) else { return nil }; return -Int64(magnitude)
      }
      // Dart's 64-bit VM interprets an unsigned hex literal as signed bits.
      return Int64(bitPattern: magnitude)
    }
    guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int64((negative ? "-" : "") + text)
  }

  private static func cookieDate(_ value: String) throws -> Int64 {
    // RFC 6265 5.1.1 delimiter tokens, rather than locale-dependent formatters.
    let tokens = value.utf16.split { unit in
      unit == 9 || (32...47).contains(unit) || (59...64).contains(unit) ||
        (91...96).contains(unit) || (123...126).contains(unit)
    }.map { String(decoding: $0, as: UTF16.self) }
    let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    var year: Int?, month: Int?, day: Int?
    var time: [Int]?
    func leadingNumber(_ source: Substring, max: Int) -> (Int, Int)? {
      let digits = source.prefix { $0 >= "0" && $0 <= "9" }
      guard !digits.isEmpty, digits.count <= max, let number = Int(digits) else { return nil }
      return (number, digits.count)
    }
    for token in tokens {
      if let number = leadingNumber(token[...], max: 4) {
        if time == nil, number.1 <= 2 {
          let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
          if pieces.count >= 3, number.1 == pieces[0].count, let minutes = leadingNumber(pieces[1], max: 2),
             minutes.1 == pieces[1].count, let seconds = leadingNumber(pieces[2], max: 2) {
            time = [number.0, minutes.0, seconds.0]; continue
          }
        }
        if day == nil && number.1 <= 2 { day = number.0 }
        else if year == nil && number.1 >= 2 { year = number.0 <= 69 ? number.0 + 2000 : number.0 <= 99 ? number.0 + 1900 : number.0 }
      } else if month == nil,
                let index = months.firstIndex(of: String(decoding: token.utf16.prefix(3), as: UTF16.self).lowercased()) {
        month = index + 1
      }
    }
    guard let year, year >= 1601, let month, let day, (1...31).contains(day), let time,
          time[0] <= 23, time[1] <= 59, time[2] <= 59 else { throw PiliNativeCookieError.invalidDate }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(year: year, month: month, day: day, hour: time[0], minute: time[1], second: time[2])
    guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else { throw PiliNativeCookieError.invalidDate }
    return Int64(date.timeIntervalSince1970) * 1_000_000
  }
}
