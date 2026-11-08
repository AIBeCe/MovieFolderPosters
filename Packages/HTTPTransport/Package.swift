// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HTTPTransport",
  platforms: [.macOS("26.5")],
  products: [.library(name: "HTTPTransport", targets: ["HTTPTransport"])],
  targets: [
    .target(name: "HTTPTransport"),
    .testTarget(name: "HTTPTransportTests", dependencies: ["HTTPTransport"])
  ],
  swiftLanguageModes: [.v6]
)
