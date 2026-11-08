// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Contracts",
  platforms: [.macOS("26.5")],
  products: [.library(name: "Contracts", targets: ["Contracts"])],
  targets: [
    .target(name: "Contracts"),
    .testTarget(name: "ContractsTests", dependencies: ["Contracts"])
  ],
  swiftLanguageModes: [.v6]
)
