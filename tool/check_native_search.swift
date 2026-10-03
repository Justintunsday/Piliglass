import Foundation

private struct CheckFailure: Error { let message: String }

@MainActor
private final class FakeTransport: PiliBridgeMethodTransport {
  typealias Reply = @Sendable (Result<PiliBridgeValue, PiliBridgeInvocationError>) -> Void
  var calls: [(String, [String: PiliBridgeValue]?)] = []
  var replies: [Reply] = []
  var immediate: Result<PiliBridgeValue, PiliBridgeInvocationError>?
  var background = false
  func invoke(_ method: String, arguments: [String: PiliBridgeValue]?, completion: @escaping Reply) {
    calls.append((method, arguments)); replies.append(completion)
    if let immediate {
      if background { DispatchQueue.global().async { completion(immediate) } }
      else { completion(immediate) }
    }
  }
}

@MainActor
private final class Pending<Value: Sendable> {
  let label: String
  let page: Int
  private var continuation: CheckedContinuation<Value, Error>?
  init(_ label: String, page: Int = 0, _ continuation: CheckedContinuation<Value, Error>) {
    self.label = label; self.page = page; self.continuation = continuation
  }
  func finish(_ result: Result<Value, Error>) {
    let waiter = continuation; continuation = nil; waiter?.resume(with: result)
  }
}

private func makeDiscovery(_ history: [String] = [], enabled: Bool = true) -> PiliSearchDiscovery {
  PiliSearchDiscovery(history: history, trending: [], recommendations: [], trendingEnabled: enabled,
                      recommendEnabled: enabled, suggestionEnabled: enabled, recordHistory: enabled)
}
private func makePage(_ ids: [String] = [], more: Bool = false, number: Int = 1) -> PiliSearchVideoPage {
  PiliSearchVideoPage(items: ids.map { PiliSearchVideoSummary(sourceID: $0, aid: nil, bvid: nil,
    title: $0, cover: nil, owner: "", viewText: "", danmakuText: "", durationText: "", pubdateText: "") },
    total: ids.count, hasMore: more, page: number)
}

@MainActor
private final class FakeRepository: PiliSearchRepository {
  var discoveries: [Pending<PiliSearchDiscovery>] = []
  var suggestions: [Pending<[String]>] = []
  var videos: [Pending<PiliSearchVideoPage>] = []
  var records: [Pending<[String]>] = []
  var mutations: [Pending<[String]>] = []
  var automaticRecords = true
  func discovery() async throws -> PiliSearchDiscovery {
    try await withCheckedThrowingContinuation { discoveries.append(Pending("discovery", $0)) }
  }
  func suggestions(for keyword: String) async throws -> [String] {
    try await withCheckedThrowingContinuation { suggestions.append(Pending(keyword, $0)) }
  }
  func videos(keyword: String, page: Int) async throws -> PiliSearchVideoPage {
    try await withCheckedThrowingContinuation { videos.append(Pending(keyword, page: page, $0)) }
  }
  func recordHistory(_ keyword: String) async throws -> [String] {
    try await withCheckedThrowingContinuation {
      let pending = Pending(keyword, $0); records.append(pending)
      if automaticRecords { pending.finish(.success([])) }
    }
  }
  func removeHistory(_ keyword: String) async throws -> [String] { try await mutate("remove:\(keyword)") }
  func clearHistory() async throws -> [String] { try await mutate("clear") }
  private func mutate(_ label: String) async throws -> [String] {
    try await withCheckedThrowingContinuation { mutations.append(Pending(label, $0)) }
  }
  func finishAll() {
    discoveries.forEach { $0.finish(.success(makeDiscovery())) }
    suggestions.forEach { $0.finish(.success([])) }
    videos.forEach { $0.finish(.success(makePage())) }
    records.forEach { $0.finish(.success([])) }
    mutations.forEach { $0.finish(.success([])) }
  }
}

@MainActor
private final class Outcome<Value: Sendable> { var result: Result<Value, Error>? }

@main @MainActor
private struct NativeSearchChecks {
  static var checks = 0
  static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
    checks += 1
  }
  static func until(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      await Task.yield(); try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CheckFailure(message: "Timed out: \(message)")
  }
  static func drain() async throws {
    for _ in 0..<5 { await Task.yield() }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  static func value<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
    let outcome = Outcome<Value>()
    let task = Task {
      do { outcome.result = .success(try await operation()) }
      catch { outcome.result = .failure(error) }
    }
    defer { task.cancel() }
    try await until("operation completed") { outcome.result != nil }
    return try outcome.result!.get()
  }
  static func failure(_ operation: @escaping @MainActor () async throws -> Void, _ matches: (Error) -> Bool) async throws {
    do { try await value(operation) }
    catch { try expect(matches(error), "Unexpected error: \(error)"); return }
    throw CheckFailure(message: "Expected an error")
  }
  static func main() async {
    do {
      try snapshotChecks(); try await bridgeChecks(); try await repositoryChecks()
      try await modelChecks(); try await historyOrderingChecks()
      print("\(checks) native search checks passed")
    } catch {
      print("FAIL native search checks: \(error)"); exit(1)
    }
  }

  static func snapshotChecks() throws {
    let large: Int64 = 9_007_199_254_740_993
    let nested = NSMutableArray(array: [NSNumber(value: large), NSNull(), ""])
    let text = NSMutableString(string: "before")
    let original = NSMutableDictionary(dictionary: ["bool": NSNumber(value: true), "int": NSNumber(value: 0),
      "float": NSNumber(value: 1.5), "nested": nested, "text": text])
    let snapshot = try PiliBridgeValue(codecValue: original)
    let expected = PiliBridgeValue.dictionary(["bool": .bool(true), "int": .integer(0), "float": .double(1.5),
      "nested": .array([.integer(large), .null, .string("")]), "text": .string("before")])
    try expect(snapshot == expected, "Snapshot distinguishes bool, integer, float, empty string, null and nesting")
    nested.removeAllObjects(); text.append("-after"); original["int"] = NSNumber(value: 99)
    try expect(snapshot == expected, "Snapshot owns mutable codec containers and strings")
    try expect(try PiliBridgeValue(codecValue: snapshot.codecValue) == expected, "Codec round trip retains large integer")
    do { _ = try PiliBridgeValue(codecValue: Date()); throw CheckFailure(message: "Unsupported codec accepted") }
    catch PiliBridgeInvocationError.invalidValue { checks += 1 }
  }

  static func bridgeChecks() async throws {
    let transport = FakeTransport()
    let active = PiliBridgeMethodInvoker(transport: transport)
    transport.immediate = .success(.string("sync"))
    try expect(try await value { try await active.invoke("sync", arguments: nil) } == .string("sync"), "Synchronous callback completes")
    transport.background = true
    try expect(try await value { try await active.invoke("background", arguments: nil) } == .string("sync"), "Background callback crosses safely")
    transport.immediate = nil; transport.background = false
    let duplicate = Task { try await active.invoke("duplicate", arguments: nil) }
    try await until("duplicate request") { transport.replies.count == 3 }
    transport.replies[2](.success(.integer(1))); transport.replies[2](.success(.integer(1)))
    try expect(try await value { try await duplicate.value } == .integer(1), "Duplicate callback resumes exactly once")
    transport.replies[2](.success(.integer(2)))
    let before = transport.calls.count
    let early = Task { try await active.invoke("cancel-before-send", arguments: nil) }; early.cancel()
    try await failure({ _ = try await early.value }, { $0 is CancellationError })
    try expect(transport.calls.count == before, "Cancelled task does not send")
    let waiting = Task { try await active.invoke("waiting", arguments: nil) }
    try await until("waiting request") { transport.calls.count == before + 1 }
    waiting.cancel()
    try await failure({ _ = try await waiting.value }, { $0 is CancellationError })
    transport.replies[before](.success(.null)); transport.replies[before](.success(.null)); try await drain()
    let racing = Task { try await active.invoke("callback-cancel-race", arguments: nil) }
    try await until("racing request") { transport.calls.count == before + 2 }
    transport.replies[before + 1](.success(.null)); racing.cancel()
    try await failure({ _ = try await racing.value }, { $0 is CancellationError })
    transport.immediate = .failure(.platform(code: "offline", message: "details"))
    try await failure({ _ = try await active.invoke("error", arguments: nil) },
                      { ($0 as? PiliBridgeInvocationError) == .platform(code: "offline", message: "details") })
    var temporary: PiliBridgeMethodInvoker? = PiliBridgeMethodInvoker(transport: transport)
    weak var weakTemporary = temporary
    _ = try? await value { try await temporary?.invoke("release", arguments: nil) }; temporary = nil; try await drain()
    try expect(weakTemporary == nil, "Completed invocation does not retain its invoker")
  }

  static func repositoryChecks() async throws {
    let transport = FakeTransport()
    let active = PiliFlutterSearchRepository(invoker: PiliBridgeMethodInvoker(transport: transport))
    transport.immediate = .success(.dictionary(["state": .string("success"), "history": .array([.string("saved"), .null, .string("")]),
      "trending": .array([.dictionary(["keyword": .string("hot"), "reason": .string("reason"), "icon": .string("icon")])]),
      "recommendations": .array([.dictionary(["keyword": .string("pick")])]), "trendingEnabled": .bool(true),
      "recommendEnabled": .integer(1), "suggestionEnabled": .string("true"), "recordHistory": .double(0)]))
    let result = try await value { try await active.discovery() }
    try expect(result.history == ["saved"] && result.trending == [PiliSearchKeyword(keyword: "hot", reason: "reason", icon: "icon")]
      && result.recommendations == [PiliSearchKeyword(keyword: "pick", reason: "", icon: nil)], "Discovery retains keyword metadata and filters empty history")
    try expect(result.trendingEnabled && result.recommendEnabled && result.suggestionEnabled && !result.recordHistory, "All four flags use legacy coercion")
    transport.immediate = .success(.dictionary(["state": .string("success"), "items": .array([.string("suggest"), .string(""), .integer(2)])]))
    try expect(try await value { try await active.suggestions(for: " input ") } == ["suggest"], "Suggestions decode only nonempty strings")
    transport.immediate = .success(.dictionary(["state": .string("success"), "total": .string("42"), "hasMore": .double(1),
      "items": .array([.dictionary(["id": .string("stable"), "aid": .integer(9_007_199_254_740_993), "bvid": .null,
        "title": .string(""), "cover": .string("cover"), "owner": .string("owner"), "viewText": .string("views"),
        "danmakuText": .string("dm"), "durationText": .string("time"), "pubdateText": .string("date")]), .null])]))
    let videos = try await value { try await active.videos(keyword: "video", page: 3) }, first = videos.items[0]
    try expect(videos.total == 42 && videos.hasMore && videos.page == 3 && first.sourceID == "stable"
      && first.aid == 9_007_199_254_740_993 && first.bvid == nil && first.title == nil && first.cover == "cover"
      && first.owner == "owner" && first.viewText == "views" && first.danmakuText == "dm"
      && first.durationText == "time" && first.pubdateText == "date", "Video fields and requested page retain codec semantics")
    try expect(videos.items[1].sourceID == "video" && videos.items[1].title == nil, "Malformed legacy video rows retain DTO defaults")
    transport.immediate = .success(.dictionary(["state": .string("success")]))
    try expect(try await value { try await active.removeHistory("saved") } == [], "Missing history defaults to empty")
    _ = try await value { try await active.clearHistory() }
    let emptyPage = try await value { try await active.videos(keyword: "first", page: 1) }
    try expect(emptyPage.items.isEmpty && emptyPage.total == 0 && !emptyPage.hasMore, "Missing video fields retain empty defaults")
    _ = try await value { try await active.recordHistory("first") }
    try expect(transport.calls.map { $0.0 } == ["loadNativeSearchDiscovery", "loadNativeSearchSuggestions", "searchVideos",
      "updateNativeSearchHistory", "updateNativeSearchHistory", "searchVideos", "updateNativeSearchHistory"],
      "Video fetching and a single explicit history add remain separate commands")
    try expect(transport.calls[0].1 == nil && transport.calls[1].1 == ["keyword": .string(" input ")]
      && transport.calls[2].1 == ["keyword": .string("video"), "page": .integer(3), "recordHistory": .bool(false)]
      && transport.calls[3].1 == ["action": .string("remove"), "keyword": .string("saved")]
      && transport.calls[4].1 == ["action": .string("clear")]
      && transport.calls[5].1 == ["keyword": .string("first"), "page": .integer(1), "recordHistory": .bool(false)]
      && transport.calls[6].1 == ["action": .string("add"), "keyword": .string("first")], "Exact arguments disable delegated auto-recording")
    for raw in [PiliBridgeValue.bool(true), .integer(9_007_199_254_740_993), .double(7.9), .string("7"), .null] {
      transport.immediate = .success(.dictionary(["state": .string("success"), "hasMore": raw,
        "items": .array([.dictionary(["aid": raw, "title": raw])])]))
      let decoded = try await value { try await active.videos(keyword: "codec", page: 1) }
      try expect(decoded.items[0].aid == piliOptionalInt(raw.codecValue)
        && decoded.items[0].title == piliString(raw.codecValue) && decoded.hasMore == piliBool(raw.codecValue),
        "Data coercion agrees with the production legacy helpers for \(raw)")
    }
    for invalid in [PiliBridgeValue.null, .dictionary([:]), .dictionary(["state": .string("loading")])] {
      transport.immediate = .success(invalid)
      try await failure({ _ = try await active.discovery() }, { ($0 as? PiliSearchRepositoryError) == .invalidResponse })
    }
    transport.immediate = .success(.dictionary(["state": .string("error"), "error": .string("API"), "code": .double(-7.9)]))
    try await failure({ _ = try await active.suggestions(for: "x") },
                      { ($0 as? PiliSearchRepositoryError) == .apiFailure(message: "API", code: -7) })
    for (bridge, domain) in [(PiliBridgeInvocationError.unavailable, PiliSearchRepositoryError.unavailable),
      (.invalidValue, .invalidResponse), (.platform(code: "wire", message: "detail"), .bridgeFailure(code: "wire", message: "detail"))] {
      transport.immediate = .failure(bridge)
      try await failure({ _ = try await active.clearHistory() }, { ($0 as? PiliSearchRepositoryError) == domain })
    }
    transport.immediate = nil
    let count = transport.calls.count, cancelled = Task { try await active.videos(keyword: "cancel", page: 1) }
    try await until("repository cancellation") { transport.calls.count == count + 1 }; cancelled.cancel()
    try await failure({ _ = try await cancelled.value }, { $0 is CancellationError })
    transport.replies[count](.success(.dictionary(["state": .string("success")]))); try await drain()
  }

  static func modelChecks() async throws {
    let repository = FakeRepository()
    let active = PiliNativeSearchModel(repository: repository, suggestionDelayNanoseconds: 0)
    defer { active.cancelSearchRequests(); repository.finishAll() }
    active.loadSearchDiscovery(); try await until("discovery") { repository.discoveries.count == 1 }
    repository.discoveries[0].finish(.success(makeDiscovery(["saved"]))); try await until("discovery applied") { !active.searchDiscoveryLoading }
    active.search("same"); try await until("first same") { repository.videos.count == 1 }
    active.search("same"); try await until("second same") { repository.videos.count == 2 }
    repository.videos[1].finish(.success(makePage(["new"]))); try await until("second same applied") { active.searchResults.first?.sourceID == "new" }
    repository.videos[0].finish(.success(makePage(["old"]))); try await drain()
    try expect(active.searchResults.map(\.sourceID) == ["new"], "Repeated same keyword rejects older response")
    for term in ["A", "B", "A"] { active.search(term); try await drain() }
    try await until("A B A requests") { repository.videos.count == 5 }
    repository.videos[4].finish(.success(makePage(["latest-A"]))); try await until("latest A") { active.searchResults.first?.sourceID == "latest-A" }
    repository.videos[2].finish(.success(makePage(["old-A"]))); repository.videos[3].finish(.success(makePage(["B"]))); try await drain()
    try expect(active.searchResults.map(\.sourceID) == ["latest-A"], "A to B to A uses request generations")
    active.updateSearchSuggestions("first"); try await until("first suggestion") { repository.suggestions.count == 1 }
    active.updateSearchSuggestions("last"); try await until("last suggestion") { repository.suggestions.count == 2 }
    repository.suggestions[1].finish(.success(["last"])); try await until("latest suggestion applied") { active.searchSuggestions == ["last"] }
    repository.suggestions[0].finish(.success(["stale"])); try await drain()
    try expect(active.searchSuggestions == ["last"], "Suggestion response ordering is guarded")
    active.updateSearchSuggestions("submit"); try await until("pending submit suggestion") { repository.suggestions.count == 3 }
    active.search("submit"); try await until("submitted video") { repository.videos.count == 6 }
    repository.suggestions[2].finish(.success(["late"])); repository.videos[5].finish(.success(makePage())); try await drain()
    try expect(active.searchSuggestions.isEmpty && active.searchSubmittedKeyword == "submit", "Submitting invalidates pending suggestions")
    active.loadSearchDiscovery(); try await until("stale discovery") { repository.discoveries.count == 2 }
    active.clearSearchHistory(); try await until("clear sent") { repository.mutations.count == 1 }
    repository.discoveries[1].finish(.success(makeDiscovery(["stale"]))); try await until("stale discovery finished") { !active.searchDiscoveryLoading }
    repository.mutations[0].finish(.success(["stale"])); try await drain()
    try expect(active.searchHistory.isEmpty, "Clear rejects stale discovery and mutation history snapshots")
    active.removeSearchHistory("a"); active.clearSearchHistory(); active.removeSearchHistory("b")
    try await until("serialized remove") { repository.mutations.count == 2 }; try await drain()
    try expect(repository.mutations.count == 2 && repository.mutations[1].label == "remove:a", "History writes serialize")
    active.cancelSearchRequests(); repository.mutations[1].finish(.success(["a"])); try await until("serialized clear") { repository.mutations.count == 3 }
    repository.mutations[2].finish(.success([])); try await until("serialized final remove") { repository.mutations.count == 4 }
    try expect(repository.mutations[2].label == "clear" && repository.mutations[3].label == "remove:b", "Disposal preserves already requested write ordering")
    repository.mutations[3].finish(.success(["b"])); try await drain()
    active.search("pages"); try await until("page one") { repository.videos.count == 7 }
    repository.videos[6].finish(.success(makePage(["1", "2"], more: true))); try await until("page one applied") { active.searchHasMore }
    active.loadMoreSearchResults(); try await until("page two") { repository.videos.count == 8 }
    repository.videos[7].finish(.failure(PiliSearchRepositoryError.apiFailure(message: "retry", code: 500)))
    try await until("page two failed") { !active.searchLoadingMore && active.searchError != nil }
    active.loadMoreSearchResults(); try await until("page two retry") { repository.videos.count == 9 }
    try expect(repository.videos[7].page == 2 && repository.videos[8].page == 2, "Failed page retries the same page")
    repository.videos[8].finish(.success(makePage(["2", "3", "3"], number: 2))); try await until("page two applied") { !active.searchLoadingMore }
    try expect(active.searchResults.map(\.sourceID) == ["1", "2", "3"] && !active.searchHasMore && active.searchError == nil, "Pagination deduplicates and successful retry clears error")
    try expect(repository.records.filter { $0.label == "pages" }.count == 1, "Pagination and retry do not record the submission twice")
    active.loadSearchDiscovery(); try await until("disabled preferences") { repository.discoveries.count == 3 }
    repository.discoveries[2].finish(.success(makeDiscovery(["stored"], enabled: false))); try await until("preferences applied") { !active.searchDiscoveryLoading }
    active.updateSearchSuggestions("disabled"); active.search("unrecorded"); try await until("unrecorded search") { repository.videos.count == 10 }; try await drain()
    try expect(repository.suggestions.count == 3 && active.searchHistory == ["stored"] && repository.records.last?.label == "unrecorded",
               "Cached disabled flags suppress optimistic history while the repository decides actual recording preference")
    repository.videos[9].finish(.success(makePage())); active.clearSearchHistory(); try await until("disabled history clear") { repository.mutations.count == 5 }
    try expect(active.searchHistory.isEmpty, "Clear works while history recording is disabled")
    repository.mutations[4].finish(.success([]))
    active.removeSearchHistory("stored"); try await until("disabled history remove") { repository.mutations.count == 6 }
    try expect(repository.mutations[5].label == "remove:stored", "Remove works while history recording is disabled")
    repository.mutations[5].finish(.success(["stale"]))
    var opened = ""; active.onOpenVideo = { video, source in opened = video.sourceID + source }
    active.openSearchVideo(PiliNativeVideo(summary: makePage(["nav"]).items[0], index: 0), sourceID: "source")
    try expect(opened == "navsource", "Search navigation remains delegated")
    active.removeSearchHistory("barrier"); active.clearSearchHistory()
    active.search("after-clear"); active.loadSearchDiscovery()
    try await until("history barrier remove") { repository.mutations.count == 7 }; try await drain()
    try expect(repository.videos.count == 10 && repository.discoveries.count == 3,
               "Search and discovery wait for earlier history writes")
    repository.mutations[6].finish(.success([])); try await until("history barrier clear") { repository.mutations.count == 8 }
    try await drain()
    try expect(repository.mutations[7].label == "clear" && repository.videos.count == 10 && repository.discoveries.count == 3,
               "Queued clear completes before page-one history recording or Hive discovery")
    repository.mutations[7].finish(.success([]))
    try await until("history barrier reads") { repository.videos.count == 11 && repository.discoveries.count == 4 }
    repository.videos[10].finish(.success(makePage(["after-clear"])))
    repository.discoveries[3].finish(.success(makeDiscovery([], enabled: false)))
    try await until("history barrier reads applied") { !active.searchLoading && !active.searchDiscoveryLoading }
    try expect(active.searchHistory.isEmpty, "Discovery after a completed clear retains empty history")
    let releaseRepository = FakeRepository()
    var temporary: PiliNativeSearchModel? = PiliNativeSearchModel(repository: releaseRepository, suggestionDelayNanoseconds: 0)
    weak var weakTemporary = temporary; temporary?.search("release")
    try await until("release request") { releaseRepository.videos.count == 1 }
    temporary?.loadSearchDiscovery(); temporary?.updateSearchSuggestions("other")
    try await until("release discovery and suggestion") { releaseRepository.discoveries.count == 1 && releaseRepository.suggestions.count == 1 }
    temporary?.cancelSearchRequests()
    try expect(temporary?.searchLoading == false && temporary?.searchDiscoveryLoading == false,
               "Disposal resets read loading state")
    temporary = nil; try await drain()
    try expect(weakTemporary == nil && releaseRepository.videos.count == 1, "Waiting read does not retain state or roll back its sent request")
    releaseRepository.finishAll(); try await drain()
  }

  static func historyOrderingChecks() async throws {
    let repository = FakeRepository(); repository.automaticRecords = false
    let active = PiliNativeSearchModel(repository: repository, suggestionDelayNanoseconds: 0)
    defer { active.cancelSearchRequests(); repository.finishAll() }
    active.removeSearchHistory("R"); active.search("S"); active.clearSearchHistory(); active.loadSearchDiscovery()
    try await until("held remove") { repository.mutations.count == 1 }; try await drain()
    try expect(repository.mutations[0].label == "remove:R" && repository.records.isEmpty && repository.videos.isEmpty
      && repository.discoveries.isEmpty, "Remove finishes before a submitted save, clear, or discovery")
    repository.mutations[0].finish(.success([])); try await until("submitted save") { repository.records.count == 1 }
    try await drain()
    try expect(repository.records[0].label == "S" && repository.mutations.count == 1 && repository.videos.isEmpty
      && repository.discoveries.isEmpty, "Submission saves exactly once ahead of clear; reads await the save")
    repository.records[0].finish(.success(["S"]))
    try await until("clear and HTTP after save") { repository.mutations.count == 2 && repository.videos.count == 1 }
    try expect(repository.mutations[1].label == "clear" && repository.discoveries.isEmpty,
               "Video HTTP waits only for its own save and runs while the later clear is pending")
    repository.mutations[1].finish(.success([])); try await until("discovery after clear") { repository.discoveries.count == 1 }
    try expect(repository.videos.count == 1, "Clear and discovery finish their ordering barrier while video HTTP remains pending")
    repository.discoveries[0].finish(.success(makeDiscovery([]))); repository.videos[0].finish(.success(makePage(["S"])))
    try await until("ordered reads applied") { !active.searchLoading && !active.searchDiscoveryLoading }
    try expect(active.searchHistory.isEmpty, "Clear keeps the saved submission out of later discovery history")

    let failedRepository = FakeRepository(); failedRepository.automaticRecords = false
    let failed = PiliNativeSearchModel(repository: failedRepository, suggestionDelayNanoseconds: 0)
    defer { failed.cancelSearchRequests(); failedRepository.finishAll() }
    failed.search("failed-save"); try await until("failing save") { failedRepository.records.count == 1 }
    failedRepository.records[0].finish(.failure(PiliSearchRepositoryError.bridgeFailure(code: "write", message: "save failed")))
    try await until("save failure applied") { !failed.searchLoading && failed.searchError != nil }
    try expect(failedRepository.videos.isEmpty, "A history-save failure prevents the video API request")
    failed.clearSearchHistory(); try await until("clear after save failure") { failedRepository.mutations.count == 1 }
    failedRepository.mutations[0].finish(.success([])); failed.search("retry-save")
    try await until("save retry") { failedRepository.records.count == 2 }; failedRepository.records[1].finish(.success([]))
    try await until("HTTP after save retry") { failedRepository.videos.count == 1 }
    failedRepository.videos[0].finish(.success(makePage())); try await until("save retry applied") { !failed.searchLoading }
    try expect(failed.searchError == nil, "A failed save does not block subsequent ordered mutations and searches")

    let durableRepository = FakeRepository(); durableRepository.automaticRecords = false
    var temporary: PiliNativeSearchModel? = PiliNativeSearchModel(repository: durableRepository, suggestionDelayNanoseconds: 0)
    weak var weakTemporary = temporary
    temporary?.removeSearchHistory("R"); temporary?.search("S"); temporary?.clearSearchHistory()
    try await until("durable held remove") { durableRepository.mutations.count == 1 }
    temporary?.cancelSearchRequests(); temporary = nil; try await drain()
    try expect(weakTemporary == nil, "Queued history work does not retain the disposed search state")
    durableRepository.mutations[0].finish(.success([])); try await until("durable submitted save") { durableRepository.records.count == 1 }
    durableRepository.records[0].finish(.success([])); try await until("durable queued clear") { durableRepository.mutations.count == 2 }
    durableRepository.mutations[1].finish(.success([])); try await drain()
    try expect(durableRepository.records[0].label == "S" && durableRepository.mutations[1].label == "clear"
      && durableRepository.videos.isEmpty, "Disposal preserves queued save and clear ordering while cancelling the HTTP wait")
    durableRepository.finishAll()
  }
}
