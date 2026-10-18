// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Log",
  platforms: [.macOS("26.5")],
  products: [.library(name: "Log", targets: ["Log"])],
  dependencies: [.package(path: "../Persistence")],
  targets: [
    .target(name: "Log", dependencies: ["Persistence"]),
    .executableTarget(name: "LogTestProbe", dependencies: ["Log"], path: "Tests/Probe"),
    .testTarget(name: "LogTests", dependencies: ["Log", "Persistence", "LogTestProbe"])
  ],
  swiftLanguageModes: [.v6]
)
