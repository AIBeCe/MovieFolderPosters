// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Network",
  platforms: [.macOS("26.5")],
  products: [.library(name: "Network", targets: ["Network"])],
  dependencies: [
    .package(path: "../Contracts"),
    .package(path: "../HTTPTransport"),
    .package(path: "../TMDb")
  ],
  targets: [
    .target(name: "Network", dependencies: ["Contracts", "HTTPTransport", "TMDb"]),
    .testTarget(name: "NetworkTests", dependencies: ["Network", "Contracts"])
  ],
  swiftLanguageModes: [.v6]
)
