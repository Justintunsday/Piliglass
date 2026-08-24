import AVFoundation
import AVKit
import AetherEngine
import Combine
import SwiftUI
import UIKit

final class PiliNativeDiagnosticLog: @unchecked Sendable {
  static let shared = PiliNativeDiagnosticLog()

  private let queue = DispatchQueue(label: "piliglass.native-diagnostic-log")
  private let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private var lines: [String] = []
  private var isAetherCaptureInstalled = false
  private let maximumLineCount = 1600

  private init() {}

  func installAetherCapture() {
    let shouldInstall = queue.sync { () -> Bool in
      guard !isAetherCaptureInstalled else { return false }
      isAetherCaptureInstalled = true
      return true
    }
    guard shouldInstall else { return }
    let previousHandler = EngineLog.handler
    EngineLog.handler = { line in
      previousHandler?(line)
      PiliNativeDiagnosticLog.shared.append(line, source: "Aether")
    }
    append("Aether diagnostic capture installed")
  }

  func append(_ message: String, source: String = "PiliGlass") {
    queue.async { [self] in
      let timestamp = formatter.string(from: Date())
      lines.append("\(timestamp) [\(source)] \(message)")
      if lines.count > maximumLineCount {
        lines.removeFirst(lines.count - maximumLineCount)
      }
    }
  }

  func snapshot() -> String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "unknown"
    let header = """
    PiliGlass native diagnostic log
    App: \(version) (\(build))
    System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
    Device: \(UIDevice.current.model)
    Generated: \(ISO8601DateFormatter().string(from: Date()))
    Note: log may contain temporary signed CDN URLs.
    ----------------------------------------------------------------
    """
    let body = queue.sync { lines.joined(separator: "\n") }
    return body.isEmpty ? "\(header)\nNo diagnostic entries." : "\(header)\n\(body)"
  }

  func clear() {
    queue.sync { lines.removeAll(keepingCapacity: true) }
    append("Diagnostic log cleared")
  }
}

// Bilibili's DASH audio is a normal fragmented MP4, but AVPlayer can reject
// the signed CDN URL before decoding it. Feeding Aether a custom seekable byte
// source forces its FFmpeg + AVSampleBufferAudioRenderer path and keeps Range,
// Referer and User-Agent under our control.
private final class PiliNativeHTTPRangeReader: IOReader, @unchecked Sendable {
  private struct FetchResult {
    let data: Data
    let dataStart: Int64
    let contentLength: Int64?
    let statusCode: Int
    let responseHost: String
  }

  private let url: URL
  private let headers: [String: String]
  private let lock = NSLock()
  private let session: URLSession
  private var position: Int64 = 0
  private var contentLength: Int64?
  private var cacheStart: Int64 = 0
  private var cache = Data()
  private var activeTask: URLSessionDataTask?
  private var closed = false

  init(url: URL, headers: [String: String]) {
    self.url = url
    self.headers = headers
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 45
    configuration.waitsForConnectivity = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 2
    session = URLSession(configuration: configuration)
  }

  deinit {
    close()
  }

  func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
    guard let buffer, size > 0 else { return 0 }
    let requestedCount = Int(size)

    while true {
      if let copied = copyCachedBytes(into: buffer, maximumCount: requestedCount) {
        return Int32(copied)
      }

      let offset: Int64? = locked {
        guard !closed else { return nil }
        if let contentLength, position >= contentLength { return nil }
        return position
      }
      guard let offset else { return locked { closed ? -1 : 0 } }

      do {
        let result = try fetchRange(
          start: offset,
          count: max(requestedCount, 1_024 * 1_024)
        )
        locked {
          if let length = result.contentLength { contentLength = length }
          cacheStart = result.dataStart
          cache = result.data
        }
        PiliNativeDiagnosticLog.shared.append(
          "Audio range received status=\(result.statusCode) "
            + "host=\(result.responseHost) offset=\(offset) bytes=\(result.data.count)"
        )
        if result.data.isEmpty { return 0 }
      } catch {
        PiliNativeDiagnosticLog.shared.append(
          "Audio range failed host=\(url.host ?? "unknown") offset=\(offset) "
            + "error=\(error.localizedDescription)"
        )
        return -1
      }
    }
  }

  func seek(offset: Int64, whence: Int32) -> Int64 {
    let operation = whence & ~Int32(0x20000) // Strip FFmpeg's AVSEEK_FORCE.
    if operation == 0x10000 { // AVSEEK_SIZE
      if let known = locked({ contentLength }) { return known }
      guard resolveMetadata() else { return -1 }
      return locked { contentLength ?? -1 }
    }

    var base: Int64
    switch operation {
    case 0: base = 0 // SEEK_SET
    case 1: base = locked { position } // SEEK_CUR
    case 2: // SEEK_END
      if locked({ contentLength }) == nil, !resolveMetadata() { return -1 }
      guard let length = locked({ contentLength }) else { return -1 }
      base = length
    default:
      return -1
    }

    let (target, overflow) = base.addingReportingOverflow(offset)
    guard !overflow, target >= 0 else { return -1 }
    return locked {
      guard !closed else { return -1 }
      position = min(target, contentLength ?? target)
      return position
    }
  }

  func cancel() {
    locked { activeTask }?.cancel()
  }

  func close() {
    let task: URLSessionDataTask? = locked {
      guard !closed else { return nil }
      closed = true
      cache.removeAll(keepingCapacity: false)
      let task = activeTask
      activeTask = nil
      return task
    }
    task?.cancel()
    session.invalidateAndCancel()
  }

  var discImageProbeEnabled: Bool { false }

  private func copyCachedBytes(
    into buffer: UnsafeMutablePointer<UInt8>,
    maximumCount: Int
  ) -> Int? {
    locked {
      guard !closed else { return -1 }
      let relative = position - cacheStart
      guard relative >= 0, relative < Int64(cache.count) else { return nil }
      let available = cache.count - Int(relative)
      let count = min(maximumCount, available)
      cache.copyBytes(
        to: buffer,
        from: Int(relative)..<(Int(relative) + count)
      )
      position += Int64(count)
      return count
    }
  }

  private func resolveMetadata() -> Bool {
    do {
      let result = try fetchRange(start: 0, count: 1)
      locked {
        if let length = result.contentLength { contentLength = length }
        if cache.isEmpty {
          cacheStart = result.dataStart
          cache = result.data
        }
      }
      return locked { contentLength != nil }
    } catch {
      PiliNativeDiagnosticLog.shared.append(
        "Audio metadata failed host=\(url.host ?? "unknown") error=\(error.localizedDescription)"
      )
      return false
    }
  }

  private func fetchRange(start: Int64, count: Int) throws -> FetchResult {
    let end = start + Int64(max(1, count)) - 1
    let rangeHeader = "bytes=\(start)-\(end)"
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue(rangeHeader, forHTTPHeaderField: "Range")

    let semaphore = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var responseData: Data?
    var response: HTTPURLResponse?
    var responseError: Error?
    let task = session.dataTask(with: request) { data, urlResponse, error in
      resultLock.lock()
      responseData = data
      response = urlResponse as? HTTPURLResponse
      responseError = error
      resultLock.unlock()
      semaphore.signal()
    }
    let canStart: Bool = locked {
      guard !closed else { return false }
      activeTask = task
      return true
    }
    guard canStart else { throw CancellationError() }
    task.resume()
    semaphore.wait()
    locked {
      if activeTask === task { activeTask = nil }
    }

    resultLock.lock()
    let data = responseData
    let http = response
    let error = responseError
    resultLock.unlock()
    if let error { throw error }
    guard let http else {
      throw NSError(
        domain: "PiliNativeHTTPRangeReader",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "CDN 未返回 HTTP 响应"]
      )
    }

    let total = Self.totalContentLength(http)
      ?? (http.statusCode == 200 && http.expectedContentLength > 0
        ? http.expectedContentLength
        : nil)
    if http.statusCode == 416 {
      return FetchResult(
        data: Data(),
        dataStart: start,
        contentLength: total,
        statusCode: http.statusCode,
        responseHost: http.url?.host ?? url.host ?? "unknown"
      )
    }
    guard (200...299).contains(http.statusCode) else {
      throw NSError(
        domain: "PiliNativeHTTPRangeReader",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "CDN 拒绝音轨请求（HTTP \(http.statusCode)）"]
      )
    }

    return FetchResult(
      data: data ?? Data(),
      // A 200 response ignored Range and therefore starts at byte zero.
      dataStart: http.statusCode == 200 ? 0 : start,
      contentLength: total,
      statusCode: http.statusCode,
      responseHost: http.url?.host ?? url.host ?? "unknown"
    )
  }

  private static func totalContentLength(_ response: HTTPURLResponse) -> Int64? {
    guard let value = response.value(forHTTPHeaderField: "Content-Range"),
          let totalText = value.split(separator: "/").last,
          totalText != "*"
    else { return nil }
    return Int64(totalText)
  }

  private func locked<T>(_ block: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return block()
  }
}

// MARK: - Custom native playback engine

struct PiliNativePlayerSegment {
  let url: URL
  let duration: TimeInterval
  let audioURL: URL?
  let alternativeURLs: [URL]
  let alternativeAudioURLs: [URL]
  let isHDR: Bool
  let qualityValue: Int
  let codec: String

  init(
    url: URL,
    duration: TimeInterval,
    audioURL: URL? = nil,
    alternativeURLs: [URL] = [],
    alternativeAudioURLs: [URL] = [],
    isHDR: Bool = false,
    qualityValue: Int = 0,
    codec: String = ""
  ) {
    self.url = url
    self.duration = duration
    self.audioURL = audioURL
    self.alternativeURLs = alternativeURLs
    self.alternativeAudioURLs = alternativeAudioURLs
    self.isHDR = isHDR
    self.qualityValue = qualityValue
    self.codec = codec
  }

  var videoURLs: [URL] { [url] + alternativeURLs }
  var audioURLs: [URL] {
    guard let audioURL = audioURL else { return alternativeAudioURLs }
    return [audioURL] + alternativeAudioURLs
  }
}

struct PiliNativePlayerQuality: Identifiable, Equatable {
  let value: Int
  let label: String

  var id: Int { value }
}

struct PiliNativeDanmakuItem: Identifiable {
  let id: String
  let progress: TimeInterval
  let mode: Int
  let fontSize: CGFloat
  let color: UIColor
  let content: String
  let weight: Int
}

@MainActor
final class PiliNativePlayerSession: NSObject, ObservableObject {
  @Published private(set) var isReady = false
  @Published private(set) var isPlaying = false
  @Published private(set) var isBuffering = false
  @Published private(set) var currentTime: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var errorMessage: String?
  @Published private(set) var qualityLabel = "清晰度"
  @Published private(set) var qualities: [PiliNativePlayerQuality] = []
  @Published private(set) var danmakuRevision = 0
  @Published var danmakuEnabled = true
  @Published var isFullscreen = false
  @Published private(set) var playbackRate: Float = 1
  @Published private(set) var isHDR = false
  @Published private(set) var hdrBrightnessActive = false

  @Published private(set) var pictureInPicturePlayer: AVPlayer?

  let engine: AetherEngine
  private let audioEngine: AetherEngine
  var onDanmakuSegmentNeeded: ((Int) -> Void)?
  var onQualityRequested: ((Int, TimeInterval) -> Void)?

  private(set) var danmakuItems: [PiliNativeDanmakuItem] = []
  private var segments: [PiliNativePlayerSegment] = []
  private var segmentOffsets: [TimeInterval] = []
  private var requestedDanmakuSegments = Set<Int>()
  private var engineCancellables = Set<AnyCancellable>()
  private var audioEngineCancellables = Set<AnyCancellable>()
  private var videoItemReady = false
  private var audioItemReady = true
  private var hasAudioTrack = false
  private var isCorrectingAudioTime = false
  private var lastAudioCorrectionHostTime: CFTimeInterval = 0
  private var shouldAutoplay = true
  private var pendingAudioSeek: TimeInterval?
  private var itemBuildGeneration = UUID()
  private var loadTask: Task<Void, Never>?
  private var activeSegmentIndex = 0
  private var isTryingVideoCandidates = false
  private weak var videoSurface: AetherPlayerView?

  private let requestHeaders = [
    "Accept": "*/*",
    "Accept-Encoding": "identity",
    "Referer": "https://www.bilibili.com/",
    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
  ]

  override init() {
    PiliNativeDiagnosticLog.shared.installAetherCapture()
    do {
      engine = try AetherEngine()
      audioEngine = try AetherEngine()
    } catch {
      fatalError("AetherEngine 初始化失败：\(error.localizedDescription)")
    }
    super.init()
    engine.videoGravity = .resizeAspect
    PiliNativeDiagnosticLog.shared.append("Native player session initialised")
    installObservers()
  }

  deinit {
    loadTask?.cancel()
  }

  func bindVideoSurface(_ surface: AetherPlayerView) {
    videoSurface = surface
    engine.bind(view: surface)
  }

  func unbindVideoSurface(_ surface: AetherPlayerView) {
    engine.unbind(view: surface)
    if videoSurface === surface { videoSurface = nil }
  }

  private func rebindVideoSurface() {
    guard let videoSurface else { return }
    engine.bind(view: videoSurface)
  }

  func configure(
    segments: [PiliNativePlayerSegment],
    durationMilliseconds: Int,
    quality: String,
    qualities: [PiliNativePlayerQuality],
    resumeAt: TimeInterval = 0,
    autoplay: Bool = true
  ) {
    guard !segments.isEmpty else {
      fail("没有可播放的视频地址")
      return
    }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Playback can still work when another audio session owns the category.
    }

    self.segments = segments
    self.qualityLabel = quality
    self.qualities = qualities
    isHDR = segments.contains(where: { $0.isHDR })
    hdrBrightnessActive = false
    shouldAutoplay = autoplay
    errorMessage = nil
    isReady = false
    isBuffering = true
    segmentOffsets = []
    var offset: TimeInterval = 0
    for segment in segments {
      segmentOffsets.append(offset)
      offset += max(0, segment.duration)
    }
    let declaredDuration = Double(durationMilliseconds) / 1000
    duration = declaredDuration > 0 ? declaredDuration : offset
    PiliNativeDiagnosticLog.shared.append(
      "Playback configure quality=\(quality) segments=\(segments.count) "
        + "durationMs=\(durationMilliseconds) autoplay=\(autoplay)"
    )
    for (index, segment) in segments.enumerated() {
      let videoHosts = Set(segment.videoURLs.compactMap(\.host)).sorted().joined(separator: ",")
      let audioHosts = Set(segment.audioURLs.compactMap(\.host)).sorted().joined(separator: ",")
      PiliNativeDiagnosticLog.shared.append(
        "Segment[\(index)] qn=\(segment.qualityValue) codec=\(segment.codec) "
          + "hdr=\(segment.isHDR) videoCandidates=\(segment.videoURLs.count) "
          + "videoHosts=\(videoHosts.isEmpty ? "none" : videoHosts) "
          + "audioCandidates=\(segment.audioURLs.count) "
          + "audioHosts=\(audioHosts.isEmpty ? "none" : audioHosts)"
      )
    }
    loadSegment(at: max(0, resumeAt), autoplay: autoplay)
  }

  func prepareDanmaku() {
    requestedDanmakuSegments.removeAll()
    danmakuItems.removeAll()
    danmakuRevision += 1
    requestDanmaku(near: currentTime)
  }

  func appendDanmaku(_ items: [PiliNativeDanmakuItem]) {
    guard !items.isEmpty else { return }
    let existing = Set(danmakuItems.map(\.id))
    danmakuItems.append(contentsOf: items.filter { !existing.contains($0.id) })
    danmakuItems.sort { lhs, rhs in
      lhs.progress == rhs.progress ? lhs.weight > rhs.weight : lhs.progress < rhs.progress
    }
    danmakuRevision += 1
  }

  func togglePlayback() {
    if isPlaying {
      pausePlayback()
    } else {
      startPlayback()
    }
  }

  func beginLoading() {
    pausePlayback()
    isReady = false
    isBuffering = true
    errorMessage = nil
    hdrBrightnessActive = false
  }

  func pausePlayback() {
    engine.pause()
    audioEngine.pause()
  }

  func seek(to target: TimeInterval, autoplay: Bool? = nil) {
    let bounded = min(max(0, target), max(duration, 0))
    let targetIndex = index(for: bounded)
    let shouldResume = autoplay ?? isPlaying
    if targetIndex != activeSegmentIndex || !isReady {
      loadSegment(at: bounded, autoplay: shouldResume)
      return
    }
    let localTime = max(0, bounded - segmentOffsets[targetIndex])
    pausePlayback()
    isBuffering = true
    let generation = UUID()
    itemBuildGeneration = generation
    Task { [weak self] in
      guard let self else { return }
      await self.engine.seek(to: localTime)
      await self.seekAudio(to: localTime)
      guard self.itemBuildGeneration == generation else { return }
      self.currentTime = bounded
      self.isBuffering = false
      if shouldResume { self.startPlayback() }
    }
  }

  func skip(by interval: TimeInterval) {
    seek(to: currentTime + interval)
  }

  func cyclePlaybackRate() {
    let values: [Float] = [1, 1.25, 1.5, 2, 0.75]
    let current = values.firstIndex(where: { abs($0 - playbackRate) < 0.01 }) ?? 0
    playbackRate = values[(current + 1) % values.count]
    engine.setRate(playbackRate)
    if isPlaying, hasAudioTrack { audioEngine.setRate(playbackRate) }
  }

  func selectQuality(_ value: Int) {
    guard qualities.contains(where: { $0.value == value }) else { return }
    onQualityRequested?(value, currentTime)
  }

  func stop() {
    loadTask?.cancel()
    loadTask = nil
    pausePlayback()
    engine.stop()
    hasAudioTrack = false
    audioEngine.stop()
    segments.removeAll()
    segmentOffsets.removeAll()
    requestedDanmakuSegments.removeAll()
    danmakuItems.removeAll()
    danmakuRevision += 1
    isReady = false
    isPlaying = false
    isBuffering = false
    currentTime = 0
    duration = 0
    errorMessage = nil
    isHDR = false
    hdrBrightnessActive = false
    pictureInPicturePlayer = nil
    isTryingVideoCandidates = false
  }

  func fail(_ message: String) {
    PiliNativeDiagnosticLog.shared.append("Playback failed: \(message)")
    pausePlayback()
    isReady = false
    isBuffering = false
    isPlaying = false
    errorMessage = message
    hdrBrightnessActive = false
  }

  private func installObservers() {
    engine.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        PiliNativeDiagnosticLog.shared.append("Engine state=\(String(describing: state))")
        self?.handleEngineState(state)
      }
      .store(in: &engineCancellables)
    engine.$isBuffering
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] buffering in
        guard let self else { return }
        PiliNativeDiagnosticLog.shared.append("Engine buffering=\(buffering)")
        self.isBuffering = buffering || self.engine.state == .loading
        if buffering {
          self.audioEngine.pause()
        } else {
          self.resumeAudioIfPossible()
        }
      }
      .store(in: &engineCancellables)
    audioEngine.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        PiliNativeDiagnosticLog.shared.append(
          "Audio engine state=\(String(describing: state))"
        )
        guard let self else { return }
        if case .error(let message) = state,
           self.hasAudioTrack,
           !self.isTryingVideoCandidates {
          self.fail("音轨播放失败：\(message)")
        }
      }
      .store(in: &audioEngineCancellables)
    audioEngine.$isBuffering
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] buffering in
        PiliNativeDiagnosticLog.shared.append("Audio engine buffering=\(buffering)")
        if !buffering { self?.resumeAudioIfPossible() }
      }
      .store(in: &audioEngineCancellables)
    engine.clock.$currentTime
      .receive(on: DispatchQueue.main)
      .sink { [weak self] time in self?.updatePlaybackTime(localTime: time) }
      .store(in: &engineCancellables)
    engine.$videoFormat
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] format in
        guard let self else { return }
        PiliNativeDiagnosticLog.shared.append("Video format=\(String(describing: format))")
        let nativeHDR = format != .sdr
        self.isHDR = nativeHDR || self.segments.contains(where: { $0.isHDR })
        self.hdrBrightnessActive = nativeHDR && self.isReady
      }
      .store(in: &engineCancellables)
    engine.$currentAVPlayer
      .receive(on: DispatchQueue.main)
      .sink { [weak self] player in self?.pictureInPicturePlayer = player }
      .store(in: &engineCancellables)
    engine.$hasFirstFrameReadyForDisplay
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] ready in
        guard ready else { return }
        // Re-attach the active renderer after its first real frame arrives. This
        // also repairs a surface that SwiftUI mounted before Aether created the
        // session's AVPlayerLayer/AVSampleBufferDisplayLayer.
        self?.rebindVideoSurface()
      }
      .store(in: &engineCancellables)
  }

  private func handleEngineState(_ state: PlaybackState) {
    switch state {
    case .idle:
      isPlaying = false
    case .loading:
      isPlaying = false
      isBuffering = true
    case .playing:
      isPlaying = true
      isBuffering = false
      resumeAudioIfPossible()
    case .paused:
      isPlaying = false
      audioEngine.pause()
    case .seeking:
      isBuffering = true
      audioEngine.pause()
    case .ended:
      isPlaying = false
      audioEngine.pause()
      let next = activeSegmentIndex + 1
      if next < segments.count {
        loadSegment(index: next, localTime: 0, autoplay: shouldAutoplay)
      }
    case .error(let message):
      if !isTryingVideoCandidates { fail(message) }
    }
  }

  private func loadSegment(at globalTime: TimeInterval, autoplay: Bool) {
    guard !segments.isEmpty else { return }
    let segmentIndex = index(for: globalTime)
    let localTime = max(0, globalTime - segmentOffsets[segmentIndex])
    loadSegment(index: segmentIndex, localTime: localTime, autoplay: autoplay)
  }

  private func loadSegment(index segmentIndex: Int, localTime: TimeInterval, autoplay: Bool) {
    guard segments.indices.contains(segmentIndex) else { return }
    loadTask?.cancel()
    pausePlayback()
    hasAudioTrack = false
    audioEngine.stop()
    isCorrectingAudioTime = false
    lastAudioCorrectionHostTime = 0
    videoItemReady = false
    audioItemReady = true
    pendingAudioSeek = localTime
    shouldAutoplay = autoplay
    activeSegmentIndex = segmentIndex
    isBuffering = true
    isReady = false
    errorMessage = nil
    hdrBrightnessActive = false
    let generation = UUID()
    itemBuildGeneration = generation
    let segment = segments[segmentIndex]
    loadTask = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(
        segment: segment,
        localTime: localTime,
        generation: generation
      )
    }
  }

  private func performLoad(
    segment: PiliNativePlayerSegment,
    localTime: TimeInterval,
    generation: UUID
  ) async {
    var videoLoaded = false
    do {
      var lastError: Error = PiliNativePlayerBuildError.noPlayableCandidate
      isTryingVideoCandidates = true
      defer { isTryingVideoCandidates = false }
      var loaded = false
      for (candidateIndex, url) in segment.videoURLs.enumerated() {
        guard !Task.isCancelled, itemBuildGeneration == generation else { return }
        do {
          PiliNativeDiagnosticLog.shared.append(
            "Opening video candidate=\(candidateIndex + 1)/\(segment.videoURLs.count) "
              + "host=\(url.host ?? "unknown") codec=\(segment.codec) qn=\(segment.qualityValue)"
          )
          engine.stop(resetDisplayCriteria: false)
          let options = LoadOptions(
            httpHeaders: requestHeaders,
            maxConcurrentSourceRequests: segment.qualityValue >= 120 ? 6 : 4,
            declaredDurationSeconds: segment.duration > 0 ? segment.duration : nil,
            forwardBufferSegments: segment.qualityValue >= 120 ? 12 : 8,
            autoplay: false
          )
          try await engine.load(url: url, startPosition: localTime, options: options)
          PiliNativeDiagnosticLog.shared.append(
            "Video candidate opened host=\(url.host ?? "unknown")"
          )
          rebindVideoSurface()
          loaded = true
          break
        } catch {
          PiliNativeDiagnosticLog.shared.append(
            "Video candidate failed host=\(url.host ?? "unknown") "
              + "error=\(error.localizedDescription)"
          )
          lastError = error
        }
      }
      isTryingVideoCandidates = false
      guard loaded else { throw lastError }
      videoLoaded = true
      guard !Task.isCancelled, itemBuildGeneration == generation else { return }

      // Open the separate DASH audio representation through Aether's dedicated
      // audio-only decoder and our seekable HTTP reader. This keeps the entire
      // audio path away from AVPlayer's rejected remote-asset probe.
      try await loadAudioTrack(for: segment, localTime: localTime)
      guard !Task.isCancelled, itemBuildGeneration == generation else { return }

      videoItemReady = true
      audioItemReady = true
      finishPreparingIfReady()
    } catch {
      guard !Task.isCancelled, itemBuildGeneration == generation else { return }
      if videoLoaded {
        fail("音轨载入失败：\(error.localizedDescription)")
      } else {
        fail("Aether 视频轨道载入失败：\(error.localizedDescription)")
      }
    }
  }

  private func loadAudioTrack(
    for segment: PiliNativePlayerSegment,
    localTime: TimeInterval
  ) async throws {
    guard !segment.audioURLs.isEmpty else {
      hasAudioTrack = false
      PiliNativeDiagnosticLog.shared.append("No separate audio track in playback response")
      return
    }

    var lastError: Error = PiliNativePlayerBuildError.noPlayableCandidate
    hasAudioTrack = false
    for (candidateIndex, url) in segment.audioURLs.enumerated() {
      guard !Task.isCancelled else { throw CancellationError() }
      do {
        PiliNativeDiagnosticLog.shared.append(
          "Opening Aether audio candidate=\(candidateIndex + 1)/\(segment.audioURLs.count) "
            + "host=\(url.host ?? "unknown")"
        )
        audioEngine.stop(resetDisplayCriteria: false)
        let reader = PiliNativeHTTPRangeReader(url: url, headers: requestHeaders)
        let options = LoadOptions(
          suppressDisplayCriteria: true,
          audioOnly: true,
          declaredDurationSeconds: segment.duration > 0 ? segment.duration : nil,
          autoplay: false
        )
        try await audioEngine.load(
          source: .custom(reader, formatHint: "mp4"),
          startPosition: localTime,
          options: options
        )
        guard !Task.isCancelled else { throw CancellationError() }
        hasAudioTrack = true
        PiliNativeDiagnosticLog.shared.append(
          "Aether audio candidate opened host=\(url.host ?? "unknown") "
            + "backend=\(audioEngine.playbackBackend.rawValue) "
            + "decoder=\(audioEngine.activeAudioDecoder ?? "unknown")"
        )
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        PiliNativeDiagnosticLog.shared.append(
          "Aether audio candidate failed host=\(url.host ?? "unknown") "
            + "error=\(error.localizedDescription)"
        )
        lastError = error
      }
    }
    throw lastError
  }

  private func finishPreparingIfReady() {
    guard videoItemReady, audioItemReady, let localTime = pendingAudioSeek else { return }
    pendingAudioSeek = nil
    Task { [weak self] in
      guard let self else { return }
      await self.seekAudio(to: localTime)
      self.isReady = true
      self.isBuffering = false
      self.errorMessage = nil
      self.hdrBrightnessActive = self.engine.videoFormat != .sdr
      if self.shouldAutoplay { self.startPlayback() }
    }
  }

  private func startPlayback() {
    PiliNativeDiagnosticLog.shared.append("Playback start requested rate=\(playbackRate)")
    engine.setRate(playbackRate)
    engine.play()
    // Audio starts from the engine's actual non-buffering transition. Starting
    // it here made it run ahead while AVPlayer was still evaluating the first
    // video buffer, followed by an audible corrective seek.
  }

  private func resumeAudioIfPossible() {
    guard isReady,
          engine.state == .playing,
          !engine.isBuffering,
          hasAudioTrack,
          audioEngine.state == .paused || audioEngine.state == .playing else { return }
    audioEngine.setRate(playbackRate)
    audioEngine.play()
    PiliNativeDiagnosticLog.shared.append("Audio resumed rate=\(playbackRate)")
  }

  private func updatePlaybackTime(localTime local: TimeInterval) {
    guard isReady, segments.indices.contains(activeSegmentIndex), local.isFinite else { return }
    synchronizeAudio(to: local)
    currentTime = min(max(0, segmentOffsets[activeSegmentIndex] + local), max(duration, 0))
    requestDanmaku(near: currentTime)
  }

  private func synchronizeAudio(to videoTime: TimeInterval) {
    guard !isCorrectingAudioTime,
          isPlaying,
          hasAudioTrack,
          audioEngine.state == .playing else { return }
    let audioTime = audioEngine.currentTime
    let drift = audioTime - videoTime
    let hostTime = CACurrentMediaTime()
    // Small AVPlayer clock differences (especially on Bluetooth routes) are
    // normal. Hard-seeking for every 220 ms discrepancy repeatedly discarded
    // the audio buffer and was heard as stutter. Correct only gross, sustained
    // drift and throttle corrections so the new buffer has time to settle.
    guard audioTime.isFinite,
          abs(drift) > 0.85,
          hostTime - lastAudioCorrectionHostTime > 3 else { return }
    isCorrectingAudioTime = true
    lastAudioCorrectionHostTime = hostTime
    PiliNativeDiagnosticLog.shared.append(
      String(format: "Audio sync correction drift=%+.3fs video=%.3f audio=%.3f", drift, videoTime, audioTime)
    )
    audioEngine.pause()
    Task { [weak self] in
      guard let self else { return }
      await self.audioEngine.seek(to: videoTime)
      self.isCorrectingAudioTime = false
      self.resumeAudioIfPossible()
    }
  }

  private func seekAudio(to time: TimeInterval) async {
    guard hasAudioTrack else { return }
    await audioEngine.seek(to: max(0, time))
  }

  private func requestDanmaku(near time: TimeInterval) {
    let segmentLength: TimeInterval = 6 * 60
    let index = max(0, Int(time / segmentLength))
    requestDanmakuSegment(index)
    if time.truncatingRemainder(dividingBy: segmentLength) > segmentLength - 30 {
      requestDanmakuSegment(index + 1)
    }
  }

  private func requestDanmakuSegment(_ index: Int) {
    guard !requestedDanmakuSegments.contains(index) else { return }
    requestedDanmakuSegments.insert(index)
    onDanmakuSegmentNeeded?(index)
  }

  private func index(for globalTime: TimeInterval) -> Int {
    guard segments.count > 1 else { return 0 }
    for index in segmentOffsets.indices.reversed() where globalTime >= segmentOffsets[index] {
      return index
    }
    return 0
  }

}

private enum PiliNativePlayerBuildError: LocalizedError {
  case missingDashTrack
  case noPlayableCandidate

  var errorDescription: String? {
    switch self {
    case .missingDashTrack: return "视频或音频轨不存在"
    case .noPlayableCandidate: return "所有原始及备用 CDN 均无法打开"
    }
  }
}

// MARK: - UIKit video surface and customizable controls

private final class PiliNativeDanmakuView: UIView {
  private var cursor = 0
  private var lastTime: TimeInterval = -1
  private var lastRevision = -1
  private var scrollingLane = 0
  private var topLane = 0
  private var bottomLane = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func render(time: TimeInterval, items: [PiliNativeDanmakuItem], revision: Int) {
    if revision != lastRevision || lastTime < 0 || time < lastTime || time - lastTime > 1.2 {
      reset(at: time, items: items, revision: revision)
    }
    let earliest = max(lastTime, time - 0.25)
    while cursor < items.count, items[cursor].progress <= time + 0.08 {
      let item = items[cursor]
      if item.progress >= earliest { display(item) }
      cursor += 1
    }
    lastTime = time
  }

  func clear() {
    subviews.forEach { $0.removeFromSuperview() }
    cursor = 0
    lastTime = -1
    lastRevision = -1
  }

  private func reset(at time: TimeInterval, items: [PiliNativeDanmakuItem], revision: Int) {
    subviews.forEach { $0.removeFromSuperview() }
    cursor = items.partitioningIndex { $0.progress > time + 0.08 }
    lastTime = time
    lastRevision = revision
    scrollingLane = 0
    topLane = 0
    bottomLane = 0
  }

  private func display(_ item: PiliNativeDanmakuItem) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let label = UILabel()
    label.numberOfLines = 1
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.95)
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = 2
    label.attributedText = NSAttributedString(
      string: item.content,
      attributes: [
        .font: UIFont.systemFont(ofSize: min(max(item.fontSize * 0.72, 13), 25), weight: .semibold),
        .foregroundColor: item.color,
        .shadow: shadow,
      ]
    )
    label.sizeToFit()
    label.alpha = 0.96
    addSubview(label)

    let laneHeight = max(25, label.bounds.height + 5)
    let laneCount = max(1, Int(bounds.height * 0.72 / laneHeight))
    switch item.mode {
    case 4:
      let lane = bottomLane % max(1, min(laneCount, 3))
      bottomLane += 1
      label.center = CGPoint(
        x: bounds.midX,
        y: bounds.height * 0.82 - CGFloat(lane) * laneHeight
      )
      fade(label)
    case 5:
      let lane = topLane % max(1, min(laneCount, 3))
      topLane += 1
      label.center = CGPoint(x: bounds.midX, y: 12 + CGFloat(lane) * laneHeight + laneHeight / 2)
      fade(label)
    default:
      let lane = scrollingLane % laneCount
      scrollingLane += 1
      label.frame.origin = CGPoint(x: bounds.width + 12, y: 10 + CGFloat(lane) * laneHeight)
      let distance = bounds.width + label.bounds.width + 24
      let duration = min(max(Double(distance / 105), 6.5), 11)
      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveLinear, .allowUserInteraction]
      ) {
        label.transform = CGAffineTransform(translationX: -distance, y: 0)
      } completion: { _ in
        label.removeFromSuperview()
      }
    }
  }

  private func fade(_ label: UILabel) {
    UIView.animate(
      withDuration: 0.25,
      delay: 3.6,
      options: [.curveEaseOut, .allowUserInteraction]
    ) {
      label.alpha = 0
    } completion: { _ in
      label.removeFromSuperview()
    }
  }
}

private extension Array {
  func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
    var low = 0
    var high = count
    while low < high {
      let middle = (low + high) / 2
      if predicate(self[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }
}

private final class PiliNativeDiagnosticLogViewController: UIViewController {
  private let textView = UITextView()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "播放器日志"
    view.backgroundColor = .systemBackground
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.alwaysBounceVertical = true
    textView.backgroundColor = .secondarySystemBackground
    textView.textColor = .label
    textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
    textView.text = PiliNativeDiagnosticLog.shared.snapshot()
    view.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(closeLog)
    )
    navigationItem.rightBarButtonItems = [
      UIBarButtonItem(
        barButtonSystemItem: .action,
        target: self,
        action: #selector(shareLog)
      ),
      UIBarButtonItem(title: "复制", style: .plain, target: self, action: #selector(copyLog)),
    ]
  }

  @objc private func closeLog() { dismiss(animated: true) }

  @objc private func copyLog() {
    UIPasteboard.general.string = textView.text
    navigationItem.prompt = "日志已复制"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      self?.navigationItem.prompt = nil
    }
  }

  @objc private func shareLog() {
    let controller = UIActivityViewController(
      activityItems: [textView.text ?? ""],
      applicationActivities: nil
    )
    controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
    present(controller, animated: true)
  }
}

final class PiliNativePlayerViewController: UIViewController {
  private let session: PiliNativePlayerSession
  private let fullscreenPresentation: Bool
  private let canvas = AetherPlayerView()
  private let danmakuView = PiliNativeDanmakuView()
  private let controls = UIView()
  private let topBar = UIStackView()
  private let bottomBar = UIStackView()
  private let playButton = UIButton(type: .system)
  private let danmakuButton = UIButton(type: .system)
  private let logButton = UIButton(type: .system)
  private let qualityButton = UIButton(type: .system)
  private let speedButton = UIButton(type: .system)
  private let fullscreenButton = UIButton(type: .system)
  private let pipButton = UIButton(type: .system)
  private let currentLabel = UILabel()
  private let durationLabel = UILabel()
  private let slider = UISlider()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let errorLabel = UILabel()
  private var pictureInPictureController: AVPictureInPictureController?
  private var cancellables = Set<AnyCancellable>()
  private var controlsHideTask: DispatchWorkItem?
  private var wasPlayingBeforeScrub = false
  private var isScrubbing = false

  init(session: PiliNativePlayerSession, fullscreen: Bool) {
    self.session = session
    fullscreenPresentation = fullscreen
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    fullscreenPresentation ? .landscape : .all
  }

  override var prefersStatusBarHidden: Bool { fullscreenPresentation }
  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

  override func viewDidLoad() {
    super.viewDidLoad()
    buildInterface()
    bindSession()
    session.bindVideoSurface(canvas)
    pipButton.isHidden = !AVPictureInPictureController.isPictureInPictureSupported()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    session.bindVideoSurface(canvas)
    if fullscreenPresentation { requestOrientation(.landscape) }
    scheduleControlsHide()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Aether owns a polymorphic CALayer. Rebinding is idempotent and keeps the
    // active layer attached when SwiftUI changes the embedded/fullscreen host.
    session.bindVideoSurface(canvas)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    controlsHideTask?.cancel()
  }

  func detachVideoSurface() {
    session.unbindVideoSurface(canvas)
  }

  private func buildInterface() {
    view.backgroundColor = .black
    [canvas, danmakuView, controls, spinner, errorLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }
    NSLayoutConstraint.activate([
      canvas.topAnchor.constraint(equalTo: view.topAnchor),
      canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      danmakuView.topAnchor.constraint(equalTo: view.topAnchor),
      danmakuView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      danmakuView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      danmakuView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      controls.topAnchor.constraint(equalTo: view.topAnchor),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
    controls.addGestureRecognizer(tap)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapSeek(_:)))
    doubleTap.numberOfTapsRequired = 2
    controls.addGestureRecognizer(doubleTap)
    tap.require(toFail: doubleTap)

    configureButton(playButton, image: "play.fill", action: #selector(togglePlayback))
    configureButton(fullscreenButton, image: fullscreenPresentation ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: #selector(toggleFullscreen))
    configureButton(pipButton, image: "pip.enter", action: #selector(togglePictureInPicture))
    configureTextButton(danmakuButton, title: "弹幕", action: #selector(toggleDanmaku))
    configureTextButton(logButton, title: "日志", action: #selector(showDiagnosticLog))
    configureTextButton(qualityButton, title: "清晰度", action: nil)
    configureTextButton(speedButton, title: "1.0x", action: #selector(changeSpeed))

    currentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    durationLabel.font = currentLabel.font
    currentLabel.textColor = .white
    durationLabel.textColor = .white
    currentLabel.text = "00:00"
    durationLabel.text = "00:00"
    slider.minimumTrackTintColor = UIColor(red: 0.93, green: 0.29, blue: 0.48, alpha: 1)
    slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.38)
    slider.addTarget(self, action: #selector(scrubStarted), for: .touchDown)
    slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
    slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

    topBar.axis = .horizontal
    topBar.alignment = .center
    topBar.spacing = 8
    topBar.addArrangedSubview(danmakuButton)
    topBar.addArrangedSubview(UIView())
    topBar.addArrangedSubview(logButton)
    topBar.addArrangedSubview(qualityButton)
    topBar.addArrangedSubview(pipButton)

    bottomBar.axis = .horizontal
    bottomBar.alignment = .center
    bottomBar.spacing = 8
    bottomBar.addArrangedSubview(playButton)
    bottomBar.addArrangedSubview(currentLabel)
    bottomBar.addArrangedSubview(slider)
    bottomBar.addArrangedSubview(durationLabel)
    bottomBar.addArrangedSubview(speedButton)
    bottomBar.addArrangedSubview(fullscreenButton)

    [topBar, bottomBar].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      controls.addSubview($0)
    }
    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.topAnchor, constant: 6),
      topBar.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 12),
      topBar.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -12),
      bottomBar.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 10),
      bottomBar.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -10),
      bottomBar.bottomAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.bottomAnchor, constant: -6),
      slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
    ])

    errorLabel.textColor = .white
    errorLabel.font = .systemFont(ofSize: 13, weight: .medium)
    errorLabel.textAlignment = .center
    errorLabel.numberOfLines = 3
    errorLabel.isHidden = true
    spinner.color = .white
    spinner.hidesWhenStopped = true
  }

  private func bindSession() {
    session.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] playing in
      self?.playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
    }.store(in: &cancellables)
    session.$isBuffering.receive(on: DispatchQueue.main).sink { [weak self] buffering in
      buffering ? self?.spinner.startAnimating() : self?.spinner.stopAnimating()
    }.store(in: &cancellables)
    session.$errorMessage.receive(on: DispatchQueue.main).sink { [weak self] message in
      self?.errorLabel.text = message
      self?.errorLabel.isHidden = message == nil
    }.store(in: &cancellables)
    session.$duration.receive(on: DispatchQueue.main).sink { [weak self] duration in
      self?.durationLabel.text = Self.formatTime(duration)
      self?.slider.maximumValue = Float(max(duration, 1))
    }.store(in: &cancellables)
    session.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] time in
      guard let self = self else { return }
      if !self.isScrubbing {
        self.currentLabel.text = Self.formatTime(time)
        self.slider.value = Float(time)
      }
      if self.session.danmakuEnabled {
        self.danmakuView.render(
          time: time,
          items: self.session.danmakuItems,
          revision: self.session.danmakuRevision
        )
      }
    }.store(in: &cancellables)
    session.$danmakuRevision.receive(on: DispatchQueue.main).sink { [weak self] _ in
      guard let self = self, self.session.danmakuEnabled else { return }
      self.danmakuView.render(
        time: self.session.currentTime,
        items: self.session.danmakuItems,
        revision: self.session.danmakuRevision
      )
    }.store(in: &cancellables)
    session.$danmakuEnabled.receive(on: DispatchQueue.main).sink { [weak self] enabled in
      self?.danmakuButton.setTitle(enabled ? "弹幕开" : "弹幕关", for: .normal)
      if !enabled { self?.danmakuView.clear() }
    }.store(in: &cancellables)
    session.$qualityLabel.receive(on: DispatchQueue.main).sink { [weak self] label in
      self?.qualityButton.setTitle(label, for: .normal)
    }.store(in: &cancellables)
    session.$qualities.receive(on: DispatchQueue.main).sink { [weak self] qualities in
      self?.updateQualityMenu(qualities)
    }.store(in: &cancellables)
    session.$playbackRate.receive(on: DispatchQueue.main).sink { [weak self] rate in
      self?.speedButton.setTitle(rate == 1 ? "1.0x" : "\(rate)x", for: .normal)
    }.store(in: &cancellables)
    session.$pictureInPicturePlayer.receive(on: DispatchQueue.main).sink { [weak self] player in
      self?.configurePictureInPicture(player: player)
    }.store(in: &cancellables)
  }

  private func configurePictureInPicture(player: AVPlayer?) {
    pictureInPictureController?.stopPictureInPicture()
    pictureInPictureController = nil
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          player != nil,
          let layer = session.engine.nativePlayerLayer else {
      pipButton.isHidden = true
      return
    }
    // Reuse Aether's visible player layer. Creating a second hidden
    // AVPlayerLayer for the same AVPlayer can leave the visible surface without
    // a video output while audio continues normally.
    pictureInPictureController = AVPictureInPictureController(playerLayer: layer)
    pipButton.isHidden = false
  }

  private func updateQualityMenu(_ qualities: [PiliNativePlayerQuality]) {
    qualityButton.menu = UIMenu(children: qualities.map { quality in
      UIAction(title: quality.label) { [weak self] _ in
        self?.session.selectQuality(quality.value)
      }
    })
    qualityButton.showsMenuAsPrimaryAction = !qualities.isEmpty
  }

  private func configureButton(_ button: UIButton, image: String, action: Selector) {
    button.tintColor = .white
    button.setImage(UIImage(systemName: image), for: .normal)
    button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  private func configureTextButton(_ button: UIButton, title: String, action: Selector?) {
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    button.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    button.layer.cornerRadius = 7
    button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    if let action = action { button.addTarget(self, action: action, for: .touchUpInside) }
  }

  @objc private func togglePlayback() { session.togglePlayback(); scheduleControlsHide() }
  @objc private func toggleDanmaku() { session.danmakuEnabled.toggle(); scheduleControlsHide() }
  @objc private func changeSpeed() { session.cyclePlaybackRate(); scheduleControlsHide() }
  @objc private func toggleFullscreen() { session.isFullscreen.toggle() }

  @objc private func showDiagnosticLog() {
    controlsHideTask?.cancel()
    let logController = PiliNativeDiagnosticLogViewController()
    let navigationController = UINavigationController(rootViewController: logController)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(navigationController, animated: true)
  }

  @objc private func togglePictureInPicture() {
    guard let controller = pictureInPictureController else { return }
    controller.isPictureInPictureActive ? controller.stopPictureInPicture() : controller.startPictureInPicture()
  }

  @objc private func toggleControls() {
    controlsHideTask?.cancel()
    UIView.animate(withDuration: 0.18) {
      self.topBar.alpha = self.topBar.alpha > 0.1 ? 0 : 1
      self.bottomBar.alpha = self.bottomBar.alpha > 0.1 ? 0 : 1
    }
    if topBar.alpha < 0.1 { scheduleControlsHide() }
  }

  @objc private func doubleTapSeek(_ gesture: UITapGestureRecognizer) {
    session.skip(by: gesture.location(in: controls).x < controls.bounds.midX ? -10 : 10)
  }

  @objc private func scrubStarted() {
    isScrubbing = true
    wasPlayingBeforeScrub = session.isPlaying
    session.pausePlayback()
    controlsHideTask?.cancel()
  }

  @objc private func scrubChanged() { currentLabel.text = Self.formatTime(Double(slider.value)) }

  @objc private func scrubEnded() {
    isScrubbing = false
    session.seek(to: Double(slider.value), autoplay: wasPlayingBeforeScrub)
    scheduleControlsHide()
  }

  private func scheduleControlsHide() {
    controlsHideTask?.cancel()
    guard session.isPlaying else { return }
    let task = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.2) {
        self?.topBar.alpha = 0
        self?.bottomBar.alpha = 0
      }
    }
    controlsHideTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
  }

  private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
    if #available(iOS 16.0, *), let scene = view.window?.windowScene {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
      setNeedsUpdateOfSupportedInterfaceOrientations()
    } else if orientations == .landscape {
      UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  static func restorePortraitOrientation() {
    if #available(iOS 16.0, *),
       let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    } else {
      UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  private static func formatTime(_ value: TimeInterval) -> String {
    guard value.isFinite, value >= 0 else { return "00:00" }
    let seconds = Int(value.rounded(.down))
    if seconds >= 3600 {
      return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

struct PiliNativePlayerView: UIViewControllerRepresentable {
  let session: PiliNativePlayerSession
  var fullscreen = false

  func makeUIViewController(context: Context) -> PiliNativePlayerViewController {
    PiliNativePlayerViewController(session: session, fullscreen: fullscreen)
  }

  func updateUIViewController(_ uiViewController: PiliNativePlayerViewController, context: Context) {}

  static func dismantleUIViewController(
    _ uiViewController: PiliNativePlayerViewController,
    coordinator: Void
  ) {
    uiViewController.detachVideoSurface()
    uiViewController.view.layer.removeAllAnimations()
  }
}
