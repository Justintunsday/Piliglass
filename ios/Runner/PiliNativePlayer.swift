import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// AVFoundation does not consistently attach Bilibili's required request
// headers to every byte-range request. Present the signed CDN URL through a
// custom scheme and service AVPlayer's requests with URLSession so DASH video
// and audio tracks keep their Range, Referer and User-Agent headers.
private final class PiliNativeAssetResourceLoader: NSObject,
  AVAssetResourceLoaderDelegate,
  URLSessionDataDelegate,
  @unchecked Sendable
{
  private final class LoadingContext {
    let request: AVAssetResourceLoadingRequest
    let rangeHeader: String

    init(request: AVAssetResourceLoadingRequest, rangeHeader: String) {
      self.request = request
      self.rangeHeader = rangeHeader
    }
  }

  private let originalURL: URL
  private let headers: [String: String]
  private let resourceQueue = DispatchQueue(label: "piliglass.asset-resource-loader")
  private let sessionQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "piliglass.asset-url-session"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  private let lock = NSLock()
  private var loadingContexts: [Int: LoadingContext] = [:]
  private var invalidated = false
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 180
    configuration.waitsForConnectivity = true
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 4
    return URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: sessionQueue
    )
  }()

  init(url: URL, headers: [String: String]) {
    originalURL = url
    self.headers = headers
    super.init()
  }

  deinit {
    invalidate()
  }

  func makeAsset() -> AVURLAsset {
    var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
    let sourceScheme = components?.scheme ?? "https"
    components?.scheme = "piliglass-\(sourceScheme)"
    let asset = AVURLAsset(url: components?.url ?? originalURL)
    asset.resourceLoader.setDelegate(self, queue: resourceQueue)
    return asset
  }

  func invalidate() {
    let shouldInvalidate: Bool = locked {
      guard !invalidated else { return false }
      invalidated = true
      loadingContexts.removeAll()
      return true
    }
    if shouldInvalidate { session.invalidateAndCancel() }
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    guard !locked({ invalidated }) else { return false }

    let dataRequest = loadingRequest.dataRequest
    let offset: Int64
    if let dataRequest = dataRequest {
      offset = dataRequest.currentOffset > 0
        ? dataRequest.currentOffset
        : dataRequest.requestedOffset
    } else {
      offset = 0
    }
    let rangeHeader: String
    if let dataRequest = dataRequest, dataRequest.requestsAllDataToEndOfResource {
      rangeHeader = "bytes=\(offset)-"
    } else if let dataRequest = dataRequest, dataRequest.requestedLength > 0 {
      let end = offset + Int64(dataRequest.requestedLength) - 1
      rangeHeader = "bytes=\(offset)-\(end)"
    } else {
      rangeHeader = "bytes=0-1"
    }

    var request = URLRequest(url: originalURL)
    request.httpMethod = "GET"
    applyHeaders(to: &request, rangeHeader: rangeHeader)
    let task = session.dataTask(with: request)
    locked {
      loadingContexts[task.taskIdentifier] = LoadingContext(
        request: loadingRequest,
        rangeHeader: rangeHeader
      )
    }
    task.resume()
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    let taskID: Int? = locked {
      guard let entry = loadingContexts.first(where: { $0.value.request === loadingRequest }) else {
        return nil
      }
      loadingContexts.removeValue(forKey: entry.key)
      return entry.key
    }
    if let taskID = taskID {
      session.getAllTasks { tasks in
        tasks.first(where: { $0.taskIdentifier == taskID })?.cancel()
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let context = locked({ loadingContexts[task.taskIdentifier] }) else {
      completionHandler(nil)
      return
    }
    var redirected = request
    applyHeaders(to: &redirected, rangeHeader: context.rangeHeader)
    completionHandler(redirected)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let context = locked({ loadingContexts[dataTask.taskIdentifier] }) else {
      completionHandler(.cancel)
      return
    }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      finish(
        taskID: dataTask.taskIdentifier,
        error: NSError(
          domain: "PiliNativeAssetResourceLoader",
          code: (response as? HTTPURLResponse)?.statusCode ?? -1,
          userInfo: [NSLocalizedDescriptionKey: "视频 CDN 拒绝了分段请求"]
        )
      )
      completionHandler(.cancel)
      return
    }

    if let information = context.request.contentInformationRequest {
      let mimeType = response.mimeType ?? "video/mp4"
      information.contentType = UTType(mimeType: mimeType)?.identifier
        ?? UTType.mpeg4Movie.identifier
      information.isByteRangeAccessSupported = http.statusCode == 206
        || (http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true)
      if let total = totalContentLength(http: http) {
        information.contentLength = total
      } else if response.expectedContentLength > 0 {
        information.contentLength = response.expectedContentLength
      }
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    locked({ loadingContexts[dataTask.taskIdentifier] })?
      .request.dataRequest?.respond(with: data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    finish(taskID: task.taskIdentifier, error: error)
  }

  private func applyHeaders(to request: inout URLRequest, rangeHeader: String) {
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue(rangeHeader, forHTTPHeaderField: "Range")
  }

  private func totalContentLength(http: HTTPURLResponse) -> Int64? {
    guard let value = http.value(forHTTPHeaderField: "Content-Range"),
          let totalText = value.split(separator: "/").last,
          totalText != "*"
    else { return nil }
    return Int64(totalText)
  }

  private func finish(taskID: Int, error: Error?) {
    guard let context = locked({ loadingContexts.removeValue(forKey: taskID) }) else { return }
    if let error = error {
      context.request.finishLoading(with: error)
    } else {
      context.request.finishLoading()
    }
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

  let player = AVQueuePlayer()
  private let audioPlayer = AVQueuePlayer()
  var onDanmakuSegmentNeeded: ((Int) -> Void)?
  var onQualityRequested: ((Int, TimeInterval) -> Void)?

  private(set) var danmakuItems: [PiliNativeDanmakuItem] = []
  private var segments: [PiliNativePlayerSegment] = []
  private var segmentOffsets: [TimeInterval] = []
  private var itemIndices: [ObjectIdentifier: Int] = [:]
  private var audioItemIndices: [ObjectIdentifier: Int] = [:]
  private var requestedDanmakuSegments = Set<Int>()
  private var timeObserver: Any?
  private var timeControlObservation: NSKeyValueObservation?
  private var itemStatusObservation: NSKeyValueObservation?
  private var audioItemStatusObservation: NSKeyValueObservation?
  private var videoItemReady = false
  private var audioItemReady = true
  private var isCorrectingAudioTime = false
  private var shouldAutoplay = true
  private var pendingSeek: TimeInterval?
  private var itemBuildGeneration = UUID()
  private var applicationObservers: [NSObjectProtocol] = []
  private let assetLoaderLock = NSLock()
  private var assetLoaders: [PiliNativeAssetResourceLoader] = []

  override init() {
    super.init()
    player.actionAtItemEnd = .advance
    player.automaticallyWaitsToMinimizeStalling = true
    player.preventsDisplaySleepDuringVideoPlayback = true
    audioPlayer.actionAtItemEnd = .advance
    audioPlayer.automaticallyWaitsToMinimizeStalling = true
    installObservers()
    installApplicationObservers()
  }

  deinit {
    if let timeObserver = timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    timeControlObservation?.invalidate()
    itemStatusObservation?.invalidate()
    audioItemStatusObservation?.invalidate()
    applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    invalidateAssetLoaders()
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
    rebuildQueue(at: max(0, resumeAt), autoplay: autoplay)
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
    player.pause()
    audioPlayer.pause()
  }

  func seek(to target: TimeInterval, autoplay: Bool? = nil) {
    let bounded = min(max(0, target), max(duration, 0))
    rebuildQueue(at: bounded, autoplay: autoplay ?? isPlaying)
  }

  func skip(by interval: TimeInterval) {
    seek(to: currentTime + interval)
  }

  func cyclePlaybackRate() {
    let values: [Float] = [1, 1.25, 1.5, 2, 0.75]
    let current = values.firstIndex(where: { abs($0 - playbackRate) < 0.01 }) ?? 0
    playbackRate = values[(current + 1) % values.count]
    if isPlaying {
      player.rate = playbackRate
      audioPlayer.rate = playbackRate
    }
  }

  func selectQuality(_ value: Int) {
    guard qualities.contains(where: { $0.value == value }) else { return }
    onQualityRequested?(value, currentTime)
  }

  func stop() {
    pausePlayback()
    player.removeAllItems()
    audioPlayer.removeAllItems()
    itemStatusObservation?.invalidate()
    itemStatusObservation = nil
    audioItemStatusObservation?.invalidate()
    audioItemStatusObservation = nil
    itemIndices.removeAll()
    audioItemIndices.removeAll()
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
    invalidateAssetLoaders()
  }

  func fail(_ message: String) {
    pausePlayback()
    isReady = false
    isBuffering = false
    isPlaying = false
    errorMessage = message
    hdrBrightnessActive = false
  }

  private func installObservers() {
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { [weak self] _ in
      self?.updatePlaybackTime()
    }
    timeControlObservation = player.observe(
      \.timeControlStatus,
      options: [.initial, .new]
    ) { [weak self] player, _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.isPlaying = player.timeControlStatus == .playing
        self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
          self.audioPlayer.pause()
        } else if player.timeControlStatus == .playing,
                  self.audioPlayer.currentItem?.status == .readyToPlay,
                  self.audioPlayer.rate == 0 {
          self.audioPlayer.playImmediately(atRate: self.playbackRate)
        }
      }
    }
  }

  private func installApplicationObservers() {
    let center = NotificationCenter.default
    applicationObservers.append(
      center.addObserver(
        forName: UIApplication.willResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.hdrBrightnessActive = false
      }
    )
    applicationObservers.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, self.isReady, self.isHDR else { return }
        self.hdrBrightnessActive = true
      }
    )
  }

  private func rebuildQueue(at globalTime: TimeInterval, autoplay: Bool) {
    guard !segments.isEmpty else { return }
    let segmentIndex = index(for: globalTime)
    let localTime = max(0, globalTime - segmentOffsets[segmentIndex])
    pausePlayback()
    player.removeAllItems()
    audioPlayer.removeAllItems()
    itemIndices.removeAll()
    audioItemIndices.removeAll()
    itemStatusObservation?.invalidate()
    audioItemStatusObservation?.invalidate()
    videoItemReady = false
    audioItemReady = true
    pendingSeek = localTime
    shouldAutoplay = autoplay
    isBuffering = true
    let generation = UUID()
    itemBuildGeneration = generation
    let sourceSegments = segments
    Task { [weak self] in
      guard let self = self else { return }
      do {
        var builtItems: [(video: AVPlayerItem, audio: AVPlayerItem?, index: Int)] = []
        for index in segmentIndex..<sourceSegments.count {
          let items = try await self.makeItems(for: sourceSegments[index])
          builtItems.append((items.video, items.audio, index))
        }
        await MainActor.run {
          guard self.itemBuildGeneration == generation else { return }
          for items in builtItems {
            self.itemIndices[ObjectIdentifier(items.video)] = items.index
            self.player.insert(items.video, after: nil)
            if let audio = items.audio {
              self.audioItemIndices[ObjectIdentifier(audio)] = items.index
              self.audioPlayer.insert(audio, after: nil)
            }
          }
          guard let first = self.player.currentItem else {
            self.fail("播放器初始化失败")
            return
          }
          self.observeStatus(of: first, audioItem: self.audioPlayer.currentItem)
        }
      } catch {
        await MainActor.run {
          guard self.itemBuildGeneration == generation else { return }
          self.fail("4K/HDR 可用轨道载入失败：\(error.localizedDescription)")
        }
      }
    }
  }

  private func makeAsset(url: URL) -> AVURLAsset {
    let headers = [
      "Accept": "*/*",
      "Accept-Encoding": "identity",
      "Referer": "https://www.bilibili.com/",
      "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
    ]
    let loader = PiliNativeAssetResourceLoader(url: url, headers: headers)
    assetLoaderLock.lock()
    assetLoaders.append(loader)
    assetLoaderLock.unlock()
    return loader.makeAsset()
  }

  private func playableAsset(
    urls: [URL],
    mediaType: AVMediaType
  ) async throws -> AVURLAsset {
    var lastError: Error = PiliNativePlayerBuildError.noPlayableCandidate
    for url in urls {
      let asset = makeAsset(url: url)
      do {
        guard try await asset.load(.isPlayable) else {
          lastError = PiliNativePlayerBuildError.noPlayableCandidate
          continue
        }
        let tracks = try await asset.loadTracks(withMediaType: mediaType)
        guard !tracks.isEmpty else {
          lastError = PiliNativePlayerBuildError.missingDashTrack
          continue
        }
        return asset
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  private func makeItems(
    for segment: PiliNativePlayerSegment
  ) async throws -> (video: AVPlayerItem, audio: AVPlayerItem?) {
    let videoAsset = try await playableAsset(urls: segment.videoURLs, mediaType: .video)
    let videoItem = AVPlayerItem(asset: videoAsset)
    videoItem.preferredForwardBufferDuration = segment.qualityValue >= 120 ? 16 : 8
    videoItem.appliesPerFrameHDRDisplayMetadata = segment.isHDR

    guard !segment.audioURLs.isEmpty else { return (videoItem, nil) }
    let audioAsset = try await playableAsset(urls: segment.audioURLs, mediaType: .audio)
    let audioItem = AVPlayerItem(asset: audioAsset)
    audioItem.preferredForwardBufferDuration = segment.qualityValue >= 120 ? 16 : 8
    return (videoItem, audioItem)
  }

  private func observeStatus(of item: AVPlayerItem, audioItem: AVPlayerItem?) {
    videoItemReady = false
    audioItemReady = audioItem == nil
    itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self, weak item] _, _ in
      DispatchQueue.main.async {
        guard let self = self, let item = item else { return }
        switch item.status {
        case .readyToPlay:
          self.videoItemReady = true
          self.finishPreparingIfReady(videoItem: item, audioItem: audioItem)
        case .failed:
          self.fail(item.error?.localizedDescription ?? "视频载入失败")
        default:
          break
        }
      }
    }
    audioItemStatusObservation = audioItem?.observe(\.status, options: [.initial, .new]) {
      [weak self, weak audioItem, weak item] _, _ in
      DispatchQueue.main.async {
        guard let self = self, let audioItem = audioItem, let item = item else { return }
        switch audioItem.status {
        case .readyToPlay:
          self.audioItemReady = true
          self.finishPreparingIfReady(videoItem: item, audioItem: audioItem)
        case .failed:
          self.fail(audioItem.error?.localizedDescription ?? "音频载入失败")
        default:
          break
        }
      }
    }
  }

  private func finishPreparingIfReady(
    videoItem: AVPlayerItem,
    audioItem: AVPlayerItem?
  ) {
    guard videoItemReady, audioItemReady, pendingSeek != nil else { return }
    let localTime = pendingSeek ?? 0
    pendingSeek = nil
    let target = CMTime(seconds: localTime, preferredTimescale: 600)
    let group = DispatchGroup()
    group.enter()
    videoItem.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
      group.leave()
    }
    if let audioItem = audioItem {
      group.enter()
      audioItem.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
        group.leave()
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self = self else { return }
      self.isReady = true
      self.isBuffering = false
      self.errorMessage = nil
      self.hdrBrightnessActive = self.isHDR
      if self.shouldAutoplay { self.startPlayback() }
    }
  }

  private func startPlayback() {
    player.playImmediately(atRate: playbackRate)
    if audioPlayer.currentItem?.status == .readyToPlay {
      audioPlayer.playImmediately(atRate: playbackRate)
    }
  }

  private func updatePlaybackTime() {
    guard let currentItem = player.currentItem,
          let segmentIndex = itemIndices[ObjectIdentifier(currentItem)] else { return }
    if currentItem.status == .failed {
      fail(currentItem.error?.localizedDescription ?? "视频播放失败")
      return
    }
    if let audioItem = audioPlayer.currentItem, audioItem.status == .failed {
      fail(audioItem.error?.localizedDescription ?? "音频播放失败")
      return
    }
    let local = currentItem.currentTime().seconds
    guard local.isFinite else { return }
    synchronizeAudio(to: local, segmentIndex: segmentIndex)
    currentTime = min(max(0, segmentOffsets[segmentIndex] + local), max(duration, 0))
    requestDanmaku(near: currentTime)
  }

  private func synchronizeAudio(to videoTime: TimeInterval, segmentIndex: Int) {
    guard !isCorrectingAudioTime,
          player.timeControlStatus == .playing,
          let audioItem = audioPlayer.currentItem,
          audioItem.status == .readyToPlay,
          audioItemIndices[ObjectIdentifier(audioItem)] == segmentIndex else { return }
    let audioTime = audioItem.currentTime().seconds
    guard audioTime.isFinite, abs(audioTime - videoTime) > 0.22 else { return }
    isCorrectingAudioTime = true
    audioItem.seek(
      to: CMTime(seconds: videoTime, preferredTimescale: 600),
      toleranceBefore: CMTime(seconds: 0.04, preferredTimescale: 600),
      toleranceAfter: CMTime(seconds: 0.04, preferredTimescale: 600)
    ) { [weak self] _ in
      DispatchQueue.main.async {
        self?.isCorrectingAudioTime = false
      }
    }
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

  private func invalidateAssetLoaders() {
    assetLoaderLock.lock()
    let loaders = assetLoaders
    assetLoaders.removeAll()
    assetLoaderLock.unlock()
    loaders.forEach { $0.invalidate() }
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

private final class PiliNativePlayerCanvasView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

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

final class PiliNativePlayerViewController: UIViewController {
  private let session: PiliNativePlayerSession
  private let fullscreenPresentation: Bool
  private let canvas = PiliNativePlayerCanvasView()
  private let danmakuView = PiliNativeDanmakuView()
  private let controls = UIView()
  private let topBar = UIStackView()
  private let bottomBar = UIStackView()
  private let playButton = UIButton(type: .system)
  private let danmakuButton = UIButton(type: .system)
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
    canvas.playerLayer.player = session.player
    canvas.playerLayer.videoGravity = .resizeAspect
    if AVPictureInPictureController.isPictureInPictureSupported() {
      pictureInPictureController = AVPictureInPictureController(playerLayer: canvas.playerLayer)
    } else {
      pipButton.isHidden = true
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if fullscreenPresentation { requestOrientation(.landscape) }
    scheduleControlsHide()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    controlsHideTask?.cancel()
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
    uiViewController.view.layer.removeAllAnimations()
  }
}
