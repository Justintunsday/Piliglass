import Combine

// The search feature reads this state without knowing the root host or transport.
// The existing root model supplies it while repository migration is in progress.
@MainActor
protocol PiliNativeSearchViewState: ObservableObject {
  var searchResults: [PiliNativeVideo] { get }
  var searchLoading: Bool { get }
  var searchLoadingMore: Bool { get }
  var searchHasMore: Bool { get }
  var searchError: String? { get }
  var searchHistory: [String] { get }
  var searchTrending: [String] { get }
  var searchRecommendations: [String] { get }
  var searchSuggestions: [String] { get }
  var searchDiscoveryLoading: Bool { get }
  var searchDiscoveryError: String? { get }
  var searchSubmittedKeyword: String { get }

  func loadSearchDiscovery()
  func updateSearchSuggestions(_ input: String)
  func removeSearchHistory(_ keyword: String)
  func clearSearchHistory()
  func search(_ keyword: String)
  func loadMoreSearchResults()
  func openSearchVideo(_ video: PiliNativeVideo, sourceID: String)
}
