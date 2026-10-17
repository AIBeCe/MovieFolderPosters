// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Persistence",
  platforms: [.macOS("26.5")],
  products: [.library(name: "Persistence", targets: ["Persistence"])],
  targets: [
    .target(name: "Persistence"),
    .executableTarget(
      name: "PersistenceTestProbe", dependencies: ["Persistence"], path: "Tests/Probe"),
    .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "PersistenceTestProbe"])
  ],
  swiftLanguageModes: [.v6]
)
