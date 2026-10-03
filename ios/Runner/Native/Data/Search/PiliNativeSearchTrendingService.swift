import Foundation

struct PiliNativeSearchTrendingService: Sendable {
  private let client: any PiliHTTPClient

  init(client: any PiliHTTPClient) {
    self.client = client
  }

  // P04a prepares and verifies this slice without wiring it into discovery.
  // The runtime caller must first obtain the recommend-account context lease.
  func keywords(headers: [String: String], limit: Int = 10) async throws -> [PiliSearchKeyword] {
    try Task.checkCancellation()
    let request = try Self.makeRequest(headers: headers, limit: limit)
    let response = try await client.send(request)
    try Task.checkCancellation()
    return try PiliSearchTrendingDecoder.decode(response)
  }

  static func makeRequest(headers: [String: String], limit: Int = 10) throws -> URLRequest {
    // The first native slice supports the current discovery limit (10) and
    // legacy helper default (30); other limits remain on the legacy route.
    guard (1...30).contains(limit) else { throw PiliHTTPClientError.invalidRequest }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "api.bilibili.com"
    components.path = "/x/v2/search/trending/ranking"
    components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
    guard let url = components.url else { throw PiliHTTPClientError.invalidRequest }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    var names = Set<String>()
    for (name, value) in headers {
      guard !name.isEmpty, name.unicodeScalars.allSatisfy(tokenCharacters.contains),
            !value.contains("\r"), !value.contains("\n"),
            names.insert(name.lowercased()).inserted,
            !["host", "content-length"].contains(name.lowercased()) else {
        throw PiliHTTPClientError.invalidRequest
      }
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }
}
