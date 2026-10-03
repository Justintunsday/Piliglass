protocol PiliSearchRepository: Sendable {
  func discovery() async throws -> PiliSearchDiscovery
  func suggestions(for keyword: String) async throws -> [String]
  func videos(keyword: String, page: Int) async throws -> PiliSearchVideoPage
  func recordHistory(_ keyword: String) async throws -> [String]
  func removeHistory(_ keyword: String) async throws -> [String]
  func clearHistory() async throws -> [String]
}

struct PiliSearchKeyword: Sendable, Equatable {
  let keyword: String
  let reason: String
  let icon: String?
}

struct PiliSearchDiscovery: Sendable, Equatable {
  let history: [String]
  let trending: [PiliSearchKeyword]
  let recommendations: [PiliSearchKeyword]
  let trendingEnabled: Bool
  let recommendEnabled: Bool
  let suggestionEnabled: Bool
  let recordHistory: Bool
}

struct PiliSearchVideoSummary: Sendable, Equatable {
  let sourceID: String
  let aid: Int?
  let bvid: String?
  let title: String?
  let cover: String?
  let owner: String
  let viewText: String
  let danmakuText: String
  let durationText: String
  let pubdateText: String
}

struct PiliSearchVideoPage: Sendable, Equatable {
  let items: [PiliSearchVideoSummary]
  let total: Int
  let hasMore: Bool
  let page: Int
}

enum PiliSearchRepositoryError: Error, Sendable, Equatable {
  case unavailable
  case invalidResponse
  case apiFailure(message: String?, code: Int?)
  case bridgeFailure(code: String, message: String?)
}
