// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Common",
  platforms: [.macOS("26.5")],
  products: [.library(name: "Common", targets: ["Common"])],
  dependencies: [
    .package(path: "../Network"),
    .package(path: "../FileSystem"),
    .package(path: "../Persistence"),
    .package(path: "../Log"),
    .package(path: "../MovieFolderParsing")
  ],
  targets: [
    .target(name: "Common",
            dependencies: ["Network", "FileSystem", "Persistence", "Log", "MovieFolderParsing"],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
    .testTarget(name: "CommonTests",
                dependencies: ["Common", "MovieFolderParsing", "Network", "FileSystem", "Persistence"],
                resources: [.process("Resources")],
                swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")])
  ],
  swiftLanguageModes: [.v6]
)
