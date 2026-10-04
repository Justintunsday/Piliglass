import Foundation

protocol PiliWBIKeyProviding: Sendable {
  func mixinKey() async throws -> String
}

/// Composition can keep the existing Dart key authority through this adapter.
/// It is not installed until a concrete bridge operation is provided.
struct PiliLegacyWBIKeyProvider: PiliWBIKeyProviding {
  let load: @Sendable () async throws -> String
  func mixinKey() async throws -> String { try await load() }
}

struct PiliWBINavKeys: Sendable, Equatable {
  let imageURL: String
  let subURL: String

  func mixinKey() throws -> String {
    do {
      return try PiliNativeSigner.mixinKey(source: Self.fileName(imageURL) + Self.fileName(subURL))
    } catch { throw PiliWBIKeyError.invalidNavKeys }
  }

  /// Port of Utils.getFileName(fileExt:false). In particular the query is
  /// ignored before looking for an extension; URL.lastPathComponent decodes.
  private static func fileName(_ value: String) throws -> String {
    let units = Array(value.utf16)
    var slash: Int?
    var dot: Int?
    var question = units.count
    for index in units.indices.reversed() {
      if units[index] == 47 { slash = index; break }
      if units[index] == 46, dot == nil { dot = index }
      if units[index] == 63 {
        question = index
        if let currentDot = dot, currentDot > question { dot = nil }
      }
    }
    guard let slash else { throw PiliWBIKeyError.invalidNavKeys }
    return String(decoding: units[(slash + 1)..<(dot ?? question)], as: UTF16.self)
  }
}

protocol PiliWBINavKeyFetching: Sendable {
  /// The future native nav service must route through the main account.
  func fetchKeys() async throws -> PiliWBINavKeys
}

struct PiliWBICacheDay: Sendable, Equatable, Codable {
  let year: Int
  let month: Int
  let day: Int
  let timeZoneIdentifier: String
}

protocol PiliWBICacheClock: Sendable {
  func today() -> PiliWBICacheDay
}

struct PiliWBISystemCacheClock: PiliWBICacheClock {
  func today() -> PiliWBICacheDay {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.dateComponents([.year, .month, .day], from: Date())
    return PiliWBICacheDay(year: date.year ?? 0, month: date.month ?? 0, day: date.day ?? 0,
                          timeZoneIdentifier: calendar.timeZone.identifier)
  }
}

struct PiliWBICachedKey: Sendable, Equatable, Codable {
  let day: PiliWBICacheDay
  let mixinKey: String
}

protocol PiliWBIKeyCacheStore: Sendable {
  func load() async throws -> PiliWBICachedKey?
  func save(_ key: PiliWBICachedKey?) async throws
}

enum PiliWBIKeyError: Error, Sendable, Equatable {
  case invalidNavKeys
  case superseded
}

/// Uninstalled native cache policy. This deliberately fixes the legacy
/// day-of-month comparison, fetch-before-cache ordering and failure caching.
/// The old WbiSign cache continues to run until a separate authority cutover.
actor PiliNativeWBIKeyProvider: PiliWBIKeyProviding {
  private struct Flight: Sendable {
    let id: UUID
    let epoch: UInt64
    let task: Task<String, Error>
  }

  private let fetcher: any PiliWBINavKeyFetching
  private let store: any PiliWBIKeyCacheStore
  private let clock: any PiliWBICacheClock
  private var cache: PiliWBICachedKey?
  private var epoch: UInt64 = 0
  private var inFlight: Flight?
  private var persistenceTail: Task<Void, Error>?
  private var persistenceTicket: UInt64 = 0

  /// A read-only epoch for explicit refresh coordination; it carries no keys.
  var cacheGeneration: UInt64 { epoch }

  init(fetcher: any PiliWBINavKeyFetching, store: any PiliWBIKeyCacheStore,
       clock: any PiliWBICacheClock = PiliWBISystemCacheClock()) {
    self.fetcher = fetcher
    self.store = store
    self.clock = clock
  }

  deinit {
    inFlight?.task.cancel()
    persistenceTail?.cancel()
  }

  func mixinKey() async throws -> String {
    try Task.checkCancellation()
    let day = clock.today()
    if let cache, cache.day == day, Self.valid(cache.mixinKey) { return cache.mixinKey }
    let flight: Flight
    if let pending = inFlight { flight = pending }
    else {
      let id = UUID()
      let capturedEpoch = epoch
      let consultPersistedCache = epoch == 0
      let task = Task { [weak self, fetcher, store] () async throws -> String in
        do {
          // An explicit invalidation forces a fetch. A clear may still be
          // queued behind an old save, so reading that old store is unsafe.
          let persisted: PiliWBICachedKey?
          if consultPersistedCache { persisted = try await store.load() }
          else { persisted = nil }
          let key: String
          if let persisted, persisted.day == day, Self.valid(persisted.mixinKey) {
            key = persisted.mixinKey
          } else {
            key = try await fetcher.fetchKeys().mixinKey()
          }
          guard let self else { throw CancellationError() }
          return try await self.complete(key: key, day: day, id: id, epoch: capturedEpoch)
        } catch {
          await self?.failed(id: id)
          throw error
        }
      }
      flight = Flight(id: id, epoch: capturedEpoch, task: task)
      inFlight = flight
    }
    // Cancelling one caller must not cancel the shared unstructured fetch.
    let key = try await flight.task.value
    try Task.checkCancellation()
    guard epoch == flight.epoch else { throw PiliWBIKeyError.superseded }
    return key
  }

  /// Composition calls this on a deliberate refresh / authority reset. A slow
  /// earlier fetch cannot repopulate the cache or overwrite a later store save.
  func invalidate() async throws {
    epoch &+= 1
    cache = nil
    inFlight?.task.cancel()
    inFlight = nil
    let operation = enqueueSave(nil)
    try await operation.task.value
    clearPersistence(ticket: operation.ticket)
  }

  private func complete(key: String, day: PiliWBICacheDay, id: UUID, epoch: UInt64) async throws -> String {
    guard inFlight?.id == id, self.epoch == epoch, clock.today() == day else {
      failed(id: id)
      throw PiliWBIKeyError.superseded
    }
    guard Self.valid(key) else { throw PiliWBIKeyError.invalidNavKeys }
    let entry = PiliWBICachedKey(day: day, mixinKey: key)
    let operation = enqueueSave(entry)
    try await operation.task.value
    clearPersistence(ticket: operation.ticket)
    guard inFlight?.id == id, self.epoch == epoch, clock.today() == day else {
      throw PiliWBIKeyError.superseded
    }
    cache = entry
    inFlight = nil
    return key
  }

  /// Serializes async persistence, including invalidation. An old save already
  /// in progress must finish before the queued clear/new save can run.
  private func enqueueSave(_ key: PiliWBICachedKey?) -> (ticket: UInt64, task: Task<Void, Error>) {
    let previous = persistenceTail
    persistenceTicket &+= 1
    let ticket = persistenceTicket
    let task = Task { [store] in
      if let previous { _ = await previous.result }
      try await store.save(key)
    }
    persistenceTail = task
    return (ticket, task)
  }
  private func clearPersistence(ticket: UInt64) {
    if persistenceTicket == ticket { persistenceTail = nil }
  }
  private func failed(id: UUID) {
    if inFlight?.id == id { inFlight = nil }
  }
  private static func valid(_ key: String) -> Bool { key.utf16.count == 32 }
}
