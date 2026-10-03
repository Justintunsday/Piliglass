import Combine
import Foundation

@MainActor
final class PiliNativeSearchModel: ObservableObject, PiliNativeSearchViewState {
  @Published private(set) var searchResults: [PiliNativeVideo] = []
  @Published private(set) var searchLoading = false
  @Published private(set) var searchLoadingMore = false
  @Published private(set) var searchHasMore = false
  @Published private(set) var searchError: String?
  @Published private(set) var searchHistory: [String] = []
  @Published private(set) var searchTrending: [String] = []
  @Published private(set) var searchRecommendations: [String] = []
  @Published private(set) var searchSuggestions: [String] = []
  @Published private(set) var searchDiscoveryLoading = false
  @Published private(set) var searchDiscoveryError: String?
  @Published private(set) var searchSubmittedKeyword = ""

  var onOpenVideo: (@MainActor (PiliNativeVideo, String) -> Void)?

  private let repository: any PiliSearchRepository
  private let suggestionDelayNanoseconds: UInt64
  private var suggestionEnabled = true
  private var recordHistory = true
  private var page = 1
  private var queryGeneration = UUID()
  private var suggestionGeneration = UUID()
  private var discoveryGeneration = UUID()
  private var historyRevision = 0
  private var historyMutationGeneration = UUID()
  private var pageTask: Task<Void, Never>?
  private var suggestionTask: Task<Void, Never>?
  private var discoveryTask: Task<Void, Never>?
  private var historyMutationTask: Task<Result<[String], Error>, Never>?

  init(repository: any PiliSearchRepository, suggestionDelayNanoseconds: UInt64 = 250_000_000) {
    self.repository = repository
    self.suggestionDelayNanoseconds = suggestionDelayNanoseconds
  }

  deinit {
    pageTask?.cancel()
    suggestionTask?.cancel()
    discoveryTask?.cancel()
  }

  func loadSearchDiscovery() {
    guard !searchDiscoveryLoading else { return }
    searchDiscoveryLoading = true
    searchDiscoveryError = nil
    let request = UUID()
    discoveryGeneration = request
    let revision = historyRevision
    let repository = repository
    let pendingHistory = historyMutationTask
    discoveryTask = Task { [weak self] in
      do {
        _ = await pendingHistory?.value
        try Task.checkCancellation()
        let result = try await repository.discovery()
        guard let self, !Task.isCancelled, self.discoveryGeneration == request else { return }
        if self.historyRevision == revision { self.searchHistory = result.history }
        self.searchTrending = result.trending.map(\.keyword)
        self.searchRecommendations = result.recommendations.map(\.keyword)
        self.suggestionEnabled = result.suggestionEnabled
        self.recordHistory = result.recordHistory
        if !result.suggestionEnabled { self.invalidateSuggestions() }
        self.searchDiscoveryLoading = false
        self.searchDiscoveryError = nil
        self.discoveryTask = nil
      } catch {
        guard let self, !Task.isCancelled, self.discoveryGeneration == request else { return }
        self.searchDiscoveryLoading = false
        self.searchDiscoveryError = self.message(for: error, fallback: "搜索内容加载失败")
        self.discoveryTask = nil
      }
    }
  }

  func updateSearchSuggestions(_ input: String) {
    invalidateSuggestions()
    let keyword = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard suggestionEnabled, !keyword.isEmpty, keyword != searchSubmittedKeyword else { return }
    let request = suggestionGeneration
    let repository = repository
    let delay = suggestionDelayNanoseconds
    suggestionTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
        let result = try await repository.suggestions(for: keyword)
        guard let self, !Task.isCancelled, self.suggestionGeneration == request else { return }
        self.searchSuggestions = result
        self.suggestionTask = nil
      } catch {
        guard let self, !Task.isCancelled, self.suggestionGeneration == request else { return }
        self.suggestionTask = nil
      }
    }
  }

  func removeSearchHistory(_ keyword: String) {
    historyRevision += 1
    searchHistory.removeAll { $0 == keyword }
    let repository = repository
    enqueueHistoryMutation { try await repository.removeHistory(keyword) }
  }

  func clearSearchHistory() {
    historyRevision += 1
    searchHistory = []
    let repository = repository
    enqueueHistoryMutation { try await repository.clearHistory() }
  }

  private func enqueueHistoryMutation(_ operation: @escaping @Sendable () async throws -> [String]) {
    let previous = historyMutationTask
    let request = UUID()
    historyMutationGeneration = request
    historyMutationTask = Task { [weak self] in
      _ = await previous?.value
      // User-requested writes keep their order even if the search view closes.
      // Returned snapshots must not overwrite newer optimistic history edits.
      let result: Result<[String], Error>
      do { result = .success(try await operation()) }
      catch { result = .failure(error) }
      if let self, self.historyMutationGeneration == request { self.historyMutationTask = nil }
      return result
    }
  }

  func search(_ keyword: String) {
    let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    pageTask?.cancel()
    queryGeneration = UUID()
    invalidateSuggestions()
    searchSubmittedKeyword = value
    historyRevision += 1
    if recordHistory {
      searchHistory.removeAll { $0 == value }
      searchHistory.insert(value, at: 0)
    }
    // The repository applies the authoritative recording preference. This
    // separates durable history ordering from the subsequent HTTP request.
    let repository = repository
    enqueueHistoryMutation { try await repository.recordHistory(value) }
    page = 1
    searchResults = []
    searchHasMore = false
    searchLoading = true
    searchLoadingMore = false
    searchError = nil
    requestPage(1, append: false)
  }

  func loadMoreSearchResults() {
    guard searchHasMore, !searchLoading, !searchLoadingMore, !searchSubmittedKeyword.isEmpty else { return }
    searchLoadingMore = true
    requestPage(page, append: true)
  }

  private func requestPage(_ requestedPage: Int, append: Bool) {
    let keyword = searchSubmittedKeyword
    let request = queryGeneration
    let repository = repository
    let pendingHistory = requestedPage == 1 ? historyMutationTask : nil
    pageTask = Task { [weak self] in
      do {
        let historyResult = await pendingHistory?.value
        try Task.checkCancellation()
        if let historyResult { _ = try historyResult.get() }
        let result = try await repository.videos(keyword: keyword, page: requestedPage)
        guard let self, !Task.isCancelled, self.queryGeneration == request else { return }
        let start = append ? self.searchResults.count : 0
        let items = result.items.enumerated().map { PiliNativeVideo(summary: $0.element, index: start + $0.offset) }
        if append {
          var sources = Set(self.searchResults.map(\.sourceID))
          self.searchResults.append(contentsOf: items.filter { sources.insert($0.sourceID).inserted })
        } else {
          self.searchResults = items
        }
        self.searchHasMore = result.hasMore && !items.isEmpty
        self.page = requestedPage + 1
        self.searchLoading = false
        self.searchLoadingMore = false
        self.searchError = nil
        self.pageTask = nil
      } catch {
        guard let self, !Task.isCancelled, self.queryGeneration == request else { return }
        self.searchLoading = false
        self.searchLoadingMore = false
        self.searchError = self.message(for: error, fallback: "搜索失败")
        self.pageTask = nil
      }
    }
  }

  func openSearchVideo(_ video: PiliNativeVideo, sourceID: String) {
    onOpenVideo?(video, sourceID)
  }

  func cancelSearchRequests() {
    queryGeneration = UUID()
    discoveryGeneration = UUID()
    invalidateSuggestions()
    pageTask?.cancel()
    discoveryTask?.cancel()
    pageTask = nil
    discoveryTask = nil
    searchLoading = false
    searchLoadingMore = false
    searchDiscoveryLoading = false
  }

  private func invalidateSuggestions() {
    suggestionGeneration = UUID()
    suggestionTask?.cancel()
    suggestionTask = nil
    searchSuggestions = []
  }

  private func message(for error: Error, fallback: String) -> String {
    if let error = error as? PiliSearchRepositoryError {
      switch error {
      case .apiFailure(let message, _), .bridgeFailure(_, let message):
        return piliLocalizedDisplay(message ?? fallback)
      case .unavailable, .invalidResponse:
        break
      }
    }
    return piliLocalizedDisplay(fallback)
  }
}
