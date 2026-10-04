// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "PiliHTTPBodyCodec",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "PiliHTTPBodyCodec", targets: ["PiliHTTPBodyCodec"])],
  dependencies: [
    // Google Brotli 1.2.0 prebuilt for device, simulator and macOS. Only the
    // decoder/common C products are linked; no encoder or C++ Swift wrapper.
    .package(url: "https://github.com/EvgenijLutz/Brotli.git", exact: "1.2.0"),
  ],
  targets: [
    .target(name: "CPiliHTTPBodyCodec", dependencies: [
      .product(name: "libbrotlidec", package: "brotli"),
      .product(name: "libbrotlicommon", package: "brotli"),
    ], linkerSettings: [.linkedLibrary("z")]),
    .target(name: "PiliHTTPBodyCodec", dependencies: ["CPiliHTTPBodyCodec"]),
    .testTarget(name: "PiliHTTPBodyCodecTests", dependencies: ["PiliHTTPBodyCodec"]),
  ]
)
