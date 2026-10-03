import Foundation
import AetherEngine

// Bilibili's DASH audio is a normal fragmented MP4, but AVPlayer can reject
// the signed CDN URL before decoding it. Feeding Aether a custom seekable byte
// source forces its FFmpeg + AVSampleBufferAudioRenderer path and keeps Range,
// Referer and User-Agent under our control.
final class PiliNativeHTTPRangeReader: IOReader, @unchecked Sendable {
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
      // Resolve Content-Length and fill the initial AAC bytes in one request.
      // A one-byte size probe forced a second TLS round-trip before FFmpeg could
      // read the first packet on every DASH start.
      let result = try fetchRange(start: 0, count: 1_024 * 1_024)
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
        userInfo: [NSLocalizedDescriptionKey: piliLocalizedFormat("CDN 拒绝音轨请求（HTTP %d）", http.statusCode)]
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

