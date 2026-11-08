// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "TMDb",
  platforms: [.macOS("26.5")],
  products: [.library(name: "TMDb", targets: ["TMDb"])],
  dependencies: [
    .package(path: "../HTTPTransport"),
    .package(path: "../Contracts")
  ],
  targets: [
    .target(name: "TMDb", dependencies: ["HTTPTransport", "Contracts"]),
    .testTarget(name: "TMDbTests", dependencies: ["TMDb", "HTTPTransport", "Contracts"])
  ],
  swiftLanguageModes: [.v6]
)
