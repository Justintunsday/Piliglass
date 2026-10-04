import Foundation

private struct CheckFailure: Error { let message: String }

private struct WireField: Decodable {
  let field: PiliSigningField
  private enum CodingKeys: String, CodingKey { case key, type, value }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let key = try values.decode(String.self, forKey: .key)
    let type = try values.decode(String.self, forKey: .type)
    let value: PiliSigningValue
    switch type {
    case "string": value = .string(try values.decode(String.self, forKey: .value))
    case "integer":
      guard let integer = Int64(try values.decode(String.self, forKey: .value)) else {
        throw CheckFailure(message: "Invalid Dart integer")
      }
      value = .integer(integer)
    case "boolean": value = .boolean(try values.decode(Bool.self, forKey: .value))
    case "strings": value = .strings(try values.decode([String].self, forKey: .value))
    case "null":
      guard try values.decodeNil(forKey: .value) else { throw CheckFailure(message: "Invalid null") }
      value = .null
    default: throw CheckFailure(message: "Unsupported actual Dart fixture type: \(type)")
    }
    field = PiliSigningField(key: key, value: value)
  }
}
private struct GoldenRecord: Decodable {
  let name: String
  let kind: String
  let epochSeconds: String
  let input: [WireField]
  let output: [WireField]
  let query: String
  let digest: String
  let mixinKey: String?
  let appKey: String?
  let appSecret: String?
  let allowReleaseNullValues: Bool?
}
private struct Encoding: Decodable { let input: String; let output: String }
private struct NavKeys: Decodable { let imageURL: String; let subURL: String; let mixinKey: String }
private struct Golden: Decodable {
  let assertionsEnabled: Bool
  let records: [GoldenRecord]
  let mixinSource: String?
  let mixinKey: String?
  let encoding: [Encoding]?
  let navKeys: [NavKeys]?
}
private struct Surrogates: Decodable { let source: String; let units: [UInt16] }

/// All mutable clock state is private and accessed under this one lock.
/// No references escape, and no lock is held across suspension.
private final class FixtureClock: PiliWBICacheClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: PiliWBICacheDay
  init(_ day: PiliWBICacheDay) { value = day }
  func today() -> PiliWBICacheDay { lock.lock(); defer { lock.unlock() }; return value }
  func set(_ day: PiliWBICacheDay) { lock.lock(); defer { lock.unlock() }; value = day }
}
private actor FixtureFetcher: PiliWBINavKeyFetching {
  private var pending: [CheckedContinuation<PiliWBINavKeys, Error>?] = []
  var count: Int { pending.count }
  func fetchKeys() async throws -> PiliWBINavKeys {
    // Deliberately ignores cancellation: production must reject stale results
    // even when a transport cannot stop a response already on its way.
    try await withCheckedThrowingContinuation { pending.append($0) }
  }
  func complete(_ index: Int, keys: PiliWBINavKeys) {
    let continuation = pending[index]
    pending[index] = nil
    continuation?.resume(returning: keys)
  }
}
private actor FixtureStore: PiliWBIKeyCacheStore {
  var current: PiliWBICachedKey?
  var writes: [PiliWBICachedKey?] = []
  var failLoad = false
  var failSave = false
  private var pauseNext = false
  private var paused: CheckedContinuation<Void, Never>?
  init(_ key: PiliWBICachedKey? = nil) { current = key }
  func load() async throws -> PiliWBICachedKey? {
    if failLoad { failLoad = false; throw CheckFailure(message: "fixture load failure") }
    return current
  }
  func save(_ key: PiliWBICachedKey?) async throws {
    if pauseNext { pauseNext = false; await withCheckedContinuation { paused = $0 } }
    if failSave { failSave = false; throw CheckFailure(message: "fixture save failure") }
    current = key
    writes.append(key)
  }
  var isPaused: Bool { paused != nil }
  func pause() { pauseNext = true }
  func release() { let continuation = paused; paused = nil; continuation?.resume() }
  func failNextLoad() { failLoad = true }
  func failNextSave() { failSave = true }
}

@main @MainActor
private struct NativeSigningChecks {
  static var checks = 0
  static let day = PiliWBICacheDay(year: 2026, month: 1, day: 5, timeZoneIdentifier: "Asia/Hong_Kong")
  static let keys = PiliWBINavKeys(
    imageURL: "https://fixture.invalid/0123456789abcdef0123456789abcdef.png",
    subURL: "https://fixture.invalid/fedcba9876543210fedcba9876543210.png?x=.txt"
  )
  static let newerKeys = PiliWBINavKeys(
    imageURL: "https://fixture.invalid/abcdefghijklmnopqrstuvwxyzABCDEF.png",
    subURL: "https://fixture.invalid/FEDCBAzyxwvutsrqponmlkjihgfedcba.png"
  )
  static func expect(_ value: Bool, _ message: String) throws {
    guard value else { throw CheckFailure(message: message) }
    checks += 1
  }
  static func until(_ message: String, _ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw CheckFailure(message: "Timed out: \(message)")
  }
  static func fails(
    _ operation: () async throws -> Void, matching: (Error) -> Bool, _ message: String
  ) async throws {
    do { try await operation() }
    catch { try expect(matching(error), "\(message): wrong error \(error)"); return }
    throw CheckFailure(message: "\(message): error expected")
  }

  static func golden(_ path: String, assertions: Bool) throws {
    let document = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    try expect(document.assertionsEnabled == assertions, "actual Dart assertion mode")
    for record in document.records {
      guard let epoch = Int64(record.epochSeconds) else { throw CheckFailure(message: "Invalid epoch") }
      let fields = record.input.map(\.field)
      let result: PiliSigningResult
      if record.kind == "wbi", let mixin = record.mixinKey {
        result = try PiliNativeSigner.wbi(fields: fields, mixinKey: mixin, epochSeconds: epoch)
      } else if record.kind == "app", let key = record.appKey, let secret = record.appSecret {
        result = try PiliNativeSigner.app(fields: fields, appKey: key, appSecret: secret,
          epochSeconds: epoch, allowReleaseNullValues: record.allowReleaseNullValues ?? false)
      } else { throw CheckFailure(message: "Unknown golden kind") }
      try expect(result.query == record.query, "\(record.name): actual Dart query bytes")
      try expect(result.digest == record.digest, "\(record.name): actual Dart MD5")
      try expect(result.fields == record.output.map(\.field), "\(record.name): unfiltered output/order/types")
    }
    if let source = document.mixinSource, let key = document.mixinKey {
      try expect(try PiliNativeSigner.mixinKey(source: source) == key, "actual Dart UTF16 mixin indices")
    }
    for record in document.encoding ?? [] {
      try expect(PiliNativeSigner.encodeComponent(record.input) == record.output, "actual Uri.encodeComponent")
    }
    for record in document.navKeys ?? [] {
      let keys = PiliWBINavKeys(imageURL: record.imageURL, subURL: record.subURL)
      try expect(try keys.mixinKey() == record.mixinKey, "actual Utils.getFileName query/extension")
    }
  }

  static func negativeInputs(_ path: String) throws {
    let record = try JSONDecoder().decode(Surrogates.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    try expect(record.units.count == 32 && record.units.contains { (0xD800...0xDFFF).contains($0) },
               "actual Dart mixin contains surrogate code units")
    do {
      _ = try PiliNativeSigner.mixinKey(source: record.source)
      throw CheckFailure(message: "Unpaired mixin surrogate accepted")
    }
    catch PiliSigningError.unpairedMixinSurrogate { checks += 1 }
    do { _ = try PiliNativeSigner.mixinKey(source: "short"); throw CheckFailure(message: "Short mixin accepted") }
    catch PiliSigningError.invalidMixinSource { checks += 1 }
    do {
      _ = try PiliNativeSigner.app(fields: [PiliSigningField(key: "nil", value: .null)],
        appKey: "key", appSecret: "secret", epochSeconds: 0)
      throw CheckFailure(message: "Debug null accepted")
    } catch PiliSigningError.nullValue { checks += 1 }
    do {
      _ = try PiliNativeSigner.wbi(fields: [PiliSigningField(key: "a", value: .string("1")),
        PiliSigningField(key: "a", value: .string("2"))], mixinKey: "", epochSeconds: 0)
      throw CheckFailure(message: "Duplicate map key accepted")
    } catch PiliSigningError.duplicateKey { checks += 1 }
    try expect(PiliSigningField(key: "é", value: .string("x")) !=
      PiliSigningField(key: "e\u{301}", value: .string("x")), "Dart distinct UTF16 keys stay distinct")
  }

  static func cacheLifecycle() async throws {
    let clock = FixtureClock(day)
    let fetcher = FixtureFetcher()
    let store = FixtureStore()
    let provider = PiliNativeWBIKeyProvider(fetcher: fetcher, store: store, clock: clock)
    let first = Task { try await provider.mixinKey() }
    let second = Task { try await provider.mixinKey() }
    try await until("one shared cold fetch") { await fetcher.count == 1 }
    await fetcher.complete(0, keys: keys)
    let expected = try keys.mixinKey()
    try expect(try await first.value == expected, "first shared result")
    try expect(try await second.value == expected, "second shared result")
    try expect(try await provider.mixinKey() == expected, "same-day memory cache")
    try expect(await fetcher.count == 1, "same-day cache avoids fetch")
    try expect(await store.writes.count == 1, "shared fetch persists once")

    let restoredFetcher = FixtureFetcher()
    let restored = PiliNativeWBIKeyProvider(fetcher: restoredFetcher, store: store, clock: clock)
    try expect(try await restored.mixinKey() == expected, "cold-start restore full day")
    try expect(await restoredFetcher.count == 0, "restore avoids network")
    clock.set(PiliWBICacheDay(year: 2027, month: 2, day: 5, timeZoneIdentifier: day.timeZoneIdentifier))
    let nextMonth = Task { try await provider.mixinKey() }
    try await until("different month/year fetch") { await fetcher.count == 2 }
    await fetcher.complete(1, keys: newerKeys)
    try expect(try await nextMonth.value == newerKeys.mixinKey(), "full date invalidates same day number")
    clock.set(PiliWBICacheDay(year: 2027, month: 2, day: 5, timeZoneIdentifier: "UTC"))
    let timezone = Task { try await provider.mixinKey() }
    try await until("timezone change fetch") { await fetcher.count == 3 }
    await fetcher.complete(2, keys: keys)
    try expect(try await timezone.value == expected, "timezone change invalidates cache")

    let cancelFetcher = FixtureFetcher()
    let cancelProvider = PiliNativeWBIKeyProvider(fetcher: cancelFetcher, store: FixtureStore(), clock: FixtureClock(day))
    let cancelled = Task { try await cancelProvider.mixinKey() }
    let survivor = Task { try await cancelProvider.mixinKey() }
    try await until("cancel fixture fetch") { await cancelFetcher.count == 1 }
    cancelled.cancel()
    await cancelFetcher.complete(0, keys: keys)
    try await fails({ _ = try await cancelled.value }, matching: { $0 is CancellationError }, "cancelled waiter")
    try expect(try await survivor.value == expected, "other waiter retains shared key")
    try expect(await cancelFetcher.count == 1, "waiter cancellation does not duplicate fetch")

    let badFetcher = FixtureFetcher()
    let badStore = FixtureStore()
    let badProvider = PiliNativeWBIKeyProvider(fetcher: badFetcher, store: badStore, clock: FixtureClock(day))
    let malformed = Task { try await badProvider.mixinKey() }
    try await until("malformed nav fetch") { await badFetcher.count == 1 }
    await badFetcher.complete(0, keys: PiliWBINavKeys(imageURL: "invalid", subURL: "invalid"))
    try await fails({ _ = try await malformed.value }, matching: { ($0 as? PiliWBIKeyError) == .invalidNavKeys },
                    "malformed nav has no empty-key success")
    try expect(await badStore.writes.isEmpty, "malformed nav does not cache failure")
    let retry = Task { try await badProvider.mixinKey() }
    try await until("failure retry") { await badFetcher.count == 2 }
    await badFetcher.complete(1, keys: keys)
    try expect(try await retry.value == expected, "failed fetch released for retry")

    let saveFetcher = FixtureFetcher()
    let saveStore = FixtureStore()
    await saveStore.failNextSave()
    let saveProvider = PiliNativeWBIKeyProvider(fetcher: saveFetcher, store: saveStore, clock: FixtureClock(day))
    let saveFailure = Task { try await saveProvider.mixinKey() }
    try await until("save failure fetch") { await saveFetcher.count == 1 }
    await saveFetcher.complete(0, keys: keys)
    try await fails({ _ = try await saveFailure.value }, matching: { $0 is CheckFailure }, "cache save error")
    let saveRetry = Task { try await saveProvider.mixinKey() }
    try await until("save error retry") { await saveFetcher.count == 2 }
    await saveFetcher.complete(1, keys: keys)
    try expect(try await saveRetry.value == expected, "persistence error does not poison next fetch")
    let loadStore = FixtureStore()
    await loadStore.failNextLoad()
    let loadFetcher = FixtureFetcher()
    let loadProvider = PiliNativeWBIKeyProvider(fetcher: loadFetcher, store: loadStore, clock: FixtureClock(day))
    try await fails({ _ = try await loadProvider.mixinKey() }, matching: { $0 is CheckFailure }, "cache load error")
    try expect(await loadFetcher.count == 0, "failed load does not send nav")
  }

  static func staleFetchAndSave() async throws {
    let fetcher = FixtureFetcher()
    let store = FixtureStore()
    let provider = PiliNativeWBIKeyProvider(fetcher: fetcher, store: store, clock: FixtureClock(day))
    let old = Task { try await provider.mixinKey() }
    try await until("old fetch") { await fetcher.count == 1 }
    try await provider.invalidate()
    let newer = Task { try await provider.mixinKey() }
    try await until("new fetch") { await fetcher.count == 2 }
    await fetcher.complete(1, keys: newerKeys)
    let expected = try newerKeys.mixinKey()
    try expect(try await newer.value == expected, "new refresh result")
    await fetcher.complete(0, keys: keys)
    try await fails({ _ = try await old.value }, matching: { ($0 as? PiliWBIKeyError) == .superseded }, "stale fetch")
    try expect(await store.current?.mixinKey == expected, "stale fetch never overwrites new save")

    let raceFetcher = FixtureFetcher()
    let raceStore = FixtureStore()
    await raceStore.pause()
    let raceProvider = PiliNativeWBIKeyProvider(fetcher: raceFetcher, store: raceStore, clock: FixtureClock(day))
    let oldSave = Task { try await raceProvider.mixinKey() }
    try await until("old save fetch") { await raceFetcher.count == 1 }
    await raceFetcher.complete(0, keys: keys)
    try await until("old save blocked") { await raceStore.isPaused }
    let invalidation = Task { try await raceProvider.invalidate() }
    try await until("invalidation epoch published") { await raceProvider.cacheGeneration == 1 }
    let newSave = Task { try await raceProvider.mixinKey() }
    try await until("new save fetch") { await raceFetcher.count == 2 }
    await raceFetcher.complete(1, keys: newerKeys)
    await raceStore.release()
    try await invalidation.value
    try await fails({ _ = try await oldSave.value }, matching: { ($0 as? PiliWBIKeyError) == .superseded },
                    "old save publication invalidated")
    try expect(try await newSave.value == expected, "new save after queued clear")
    let writes = await raceStore.writes
    try expect(writes.count == 3 && writes[1] == nil, "save/clear/save ordering under suspension")
    try expect(await raceStore.current?.mixinKey == expected, "latest persisted key wins")

    let clock = FixtureClock(day)
    let midnightFetcher = FixtureFetcher()
    let midnightStore = FixtureStore()
    let midnightProvider = PiliNativeWBIKeyProvider(fetcher: midnightFetcher, store: midnightStore, clock: clock)
    let midnight = Task { try await midnightProvider.mixinKey() }
    try await until("midnight fetch") { await midnightFetcher.count == 1 }
    clock.set(PiliWBICacheDay(year: 2026, month: 1, day: 6, timeZoneIdentifier: day.timeZoneIdentifier))
    await midnightFetcher.complete(0, keys: keys)
    try await fails({ _ = try await midnight.value }, matching: { ($0 as? PiliWBIKeyError) == .superseded }, "day boundary")
    try expect(await midnightStore.writes.isEmpty, "old-day result not persisted")
  }

  static func main() async {
    do {
      guard CommandLine.arguments.count == 4 else { throw CheckFailure(message: "Dart golden paths required") }
      try golden(CommandLine.arguments[1], assertions: true)
      try golden(CommandLine.arguments[2], assertions: false)
      try negativeInputs(CommandLine.arguments[3])
      try await cacheLifecycle()
      try await staleFetchAndSave()
      print("\(checks) native signing and key-cache checks passed")
    } catch {
      print("FAIL native signing and key-cache: \(error)")
      exit(1)
    }
  }
}
