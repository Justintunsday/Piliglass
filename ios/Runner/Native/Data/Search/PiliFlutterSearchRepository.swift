import Foundation

@MainActor
final class PiliFlutterSearchRepository: PiliSearchRepository {
  private let invoker: any PiliBridgeMethodInvoking

  init(invoker: any PiliBridgeMethodInvoking) {
    self.invoker = invoker
  }

  func discovery() async throws -> PiliSearchDiscovery {
    let result = try await response("loadNativeSearchDiscovery")
    return PiliSearchDiscovery(
      history: PiliSearchBridgeDecoder.strings(result["history"]),
      trending: PiliSearchBridgeDecoder.keywords(result["trending"]),
      recommendations: PiliSearchBridgeDecoder.keywords(result["recommendations"]),
      trendingEnabled: PiliSearchBridgeDecoder.bool(result["trendingEnabled"]),
      recommendEnabled: PiliSearchBridgeDecoder.bool(result["recommendEnabled"]),
      suggestionEnabled: PiliSearchBridgeDecoder.bool(result["suggestionEnabled"]),
      recordHistory: PiliSearchBridgeDecoder.bool(result["recordHistory"])
    )
  }

  func suggestions(for keyword: String) async throws -> [String] {
    let result = try await response(
      "loadNativeSearchSuggestions",
      arguments: ["keyword": .string(keyword)]
    )
    return PiliSearchBridgeDecoder.strings(result["items"])
  }

  func videos(keyword: String, page: Int) async throws -> PiliSearchVideoPage {
    // The feature serializes explicit history writes before page one.
    let result = try await response(
      "searchVideos",
      arguments: ["keyword": .string(keyword), "page": .integer(Int64(page)), "recordHistory": .bool(false)]
    )
    return PiliSearchVideoPage(
      items: PiliSearchBridgeDecoder.array(result["items"]).map(PiliSearchBridgeDecoder.video),
      total: PiliSearchBridgeDecoder.int(result["total"]) ?? 0,
      hasMore: PiliSearchBridgeDecoder.bool(result["hasMore"]),
      page: page
    )
  }

  func recordHistory(_ keyword: String) async throws -> [String] {
    let result = try await response(
      "updateNativeSearchHistory",
      arguments: ["action": .string("add"), "keyword": .string(keyword)]
    )
    return PiliSearchBridgeDecoder.strings(result["history"])
  }

  func removeHistory(_ keyword: String) async throws -> [String] {
    let result = try await response(
      "updateNativeSearchHistory",
      arguments: ["action": .string("remove"), "keyword": .string(keyword)]
    )
    return PiliSearchBridgeDecoder.strings(result["history"])
  }

  func clearHistory() async throws -> [String] {
    let result = try await response(
      "updateNativeSearchHistory",
      arguments: ["action": .string("clear")]
    )
    return PiliSearchBridgeDecoder.strings(result["history"])
  }

  private func response(
    _ method: String,
    arguments: [String: PiliBridgeValue]? = nil
  ) async throws -> [String: PiliBridgeValue] {
    let value: PiliBridgeValue
    do {
      try Task.checkCancellation()
      value = try await invoker.invoke(method, arguments: arguments)
      try Task.checkCancellation()
    } catch let error as PiliBridgeInvocationError {
      switch error {
      case .unavailable:
        throw PiliSearchRepositoryError.unavailable
      case .invalidValue:
        throw PiliSearchRepositoryError.invalidResponse
      case .platform(let code, let message):
        throw PiliSearchRepositoryError.bridgeFailure(code: code, message: message)
      }
    }

    guard case .dictionary(let result) = value else {
      throw PiliSearchRepositoryError.invalidResponse
    }
    switch PiliSearchBridgeDecoder.string(result["state"]) {
    case "success":
      return result
    case "error":
      throw PiliSearchRepositoryError.apiFailure(
        message: PiliSearchBridgeDecoder.string(result["error"]),
        code: PiliSearchBridgeDecoder.int(result["code"])
      )
    default:
      throw PiliSearchRepositoryError.invalidResponse
    }
  }
}

private enum PiliSearchBridgeDecoder {
  static func string(_ value: PiliBridgeValue?) -> String? {
    guard case .string(let string) = value, !string.isEmpty else { return nil }
    return string
  }

  static func int(_ value: PiliBridgeValue?) -> Int? {
    switch value {
    case .bool(let bool):
      return bool ? 1 : 0
    case .integer(let integer):
      return NSNumber(value: integer).intValue
    case .double(let double):
      return NSNumber(value: double).intValue
    case .string(let string):
      return Int(string)
    default:
      return nil
    }
  }

  static func bool(_ value: PiliBridgeValue?) -> Bool {
    switch value {
    case .bool(let bool):
      return bool
    case .integer(let integer):
      return integer != 0
    case .double(let double):
      return NSNumber(value: double).boolValue
    case .string(let string):
      return string == "true" || string == "1"
    default:
      return false
    }
  }

  static func array(_ value: PiliBridgeValue?) -> [PiliBridgeValue] {
    guard case .array(let array) = value else { return [] }
    return array
  }

  static func strings(_ value: PiliBridgeValue?) -> [String] {
    array(value).compactMap(string)
  }

  static func keywords(_ value: PiliBridgeValue?) -> [PiliSearchKeyword] {
    array(value).compactMap { item in
      guard case .dictionary(let fields) = item,
            let keyword = string(fields["keyword"]) else { return nil }
      return PiliSearchKeyword(
        keyword: keyword,
        reason: string(fields["reason"]) ?? "",
        icon: string(fields["icon"])
      )
    }
  }

  static func video(_ value: PiliBridgeValue) -> PiliSearchVideoSummary {
    let fields: [String: PiliBridgeValue]
    if case .dictionary(let dictionary) = value {
      fields = dictionary
    } else {
      fields = [:]
    }
    return PiliSearchVideoSummary(
      sourceID: string(fields["id"]) ?? "video",
      aid: int(fields["aid"]),
      bvid: string(fields["bvid"]),
      title: string(fields["title"]),
      cover: string(fields["cover"]),
      owner: string(fields["owner"]) ?? "",
      viewText: string(fields["viewText"]) ?? "",
      danmakuText: string(fields["danmakuText"]) ?? "",
      durationText: string(fields["durationText"]) ?? "",
      pubdateText: string(fields["pubdateText"]) ?? ""
    )
  }
}
