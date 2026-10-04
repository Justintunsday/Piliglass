// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "PiliHTTPTransport",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "PiliHTTPTransport", targets: ["PiliHTTPTransport"])],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.1"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0"),
  ],
  targets: [
    .target(name: "PiliHTTPTransport", dependencies: [
      .product(name: "AsyncHTTPClient", package: "async-http-client"),
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOHTTP1", package: "swift-nio"),
    ]),
    .testTarget(name: "PiliHTTPTransportTests", dependencies: ["PiliHTTPTransport"]),
  ]
)
