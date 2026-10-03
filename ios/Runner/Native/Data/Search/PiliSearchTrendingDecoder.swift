import Foundation

enum PiliSearchTrendingError: Error, Sendable, Equatable {
  case httpStatus(Int)
  case invalidPayload
  case api(code: Int, message: String?)
}

enum PiliSearchTrendingDecoder {
  static func decode(_ response: PiliHTTPResponse) throws -> [PiliSearchKeyword] {
    guard (200..<300).contains(response.statusCode) else {
      throw PiliSearchTrendingError.httpStatus(response.statusCode)
    }
    guard response.url.scheme == "https", response.url.host == "api.bilibili.com",
          response.url.path == "/x/v2/search/trending/ranking" else {
      throw PiliHTTPClientError.invalidResponse
    }
    let envelope: Envelope
    do { envelope = try JSONDecoder().decode(Envelope.self, from: response.body) }
    catch { throw PiliSearchTrendingError.invalidPayload }
    guard envelope.code == 0 else {
      throw PiliSearchTrendingError.api(code: envelope.code, message: envelope.message)
    }
    guard let payload = envelope.data else { throw PiliSearchTrendingError.invalidPayload }
    return (payload.list ?? []).filter { !$0.keyword.isEmpty }.map { item in
      var reason = item.recommendReason ?? ""
      if let dot = reason.range(of: "·") { reason.replaceSubrange(dot, with: " ") }
      return PiliSearchKeyword(keyword: item.keyword, reason: reason, icon: normalizeIcon(item.icon))
    }
  }

  private static func normalizeIcon(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "null" else { return nil }
    if trimmed.hasPrefix("//") { return "https:" + trimmed }
    if trimmed.hasPrefix("http://") { return "https://" + String(trimmed.dropFirst(7)) }
    return trimmed
  }

  private struct Envelope: Decodable {
    let code: Int
    let message: String?
    let data: Payload?
    enum CodingKeys: String, CodingKey { case code, message, data }
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      code = try values.decode(Int.self, forKey: .code)
      message = code == 0 ? nil : try values.decodeIfPresent(String.self, forKey: .message)
      // An error envelope need not contain a correctly typed success payload.
      data = code == 0 ? try values.decodeIfPresent(Payload.self, forKey: .data) : nil
    }
  }

  private struct Payload: Decodable {
    let list: [Item]?
  }

  private struct Item: Decodable {
    let keyword: String
    let icon: String?
    let recommendReason: String?
    enum CodingKeys: String, CodingKey {
      case keyword, icon
      case recommendReason = "recommend_reason"
      case showName = "show_name"
      case showLiveIcon = "show_live_icon"
    }
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      keyword = try values.decode(String.self, forKey: .keyword)
      icon = try values.decodeIfPresent(String.self, forKey: .icon)
      recommendReason = try values.decodeIfPresent(String.self, forKey: .recommendReason)
      // Dart validates these fields even though the current native UI omits them.
      _ = try values.decodeIfPresent(String.self, forKey: .showName)
      _ = try values.decodeIfPresent(Bool.self, forKey: .showLiveIcon)
    }
  }
}
