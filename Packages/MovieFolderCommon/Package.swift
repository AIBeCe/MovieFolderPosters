// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MovieFolderCommon",
  platforms: [.macOS("26.5")],
  products: [.library(name: "MovieFolderCommon", targets: ["MovieFolderCommon"])],
  dependencies: [
    .package(path: "../Network"),
    .package(path: "../FileSystem"),
    .package(path: "../Persistence"),
    .package(path: "../Log"),
    .package(path: "../MovieFolderParsing")
  ],
  targets: [
    .target(name: "MovieFolderCommon",
            dependencies: ["Network", "FileSystem", "Persistence", "Log", "MovieFolderParsing"],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
    .testTarget(name: "MovieFolderCommonTests",
                dependencies: ["MovieFolderCommon", "MovieFolderParsing", "Network", "FileSystem", "Persistence"],
                resources: [.process("Resources")],
                swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")])
  ],
  swiftLanguageModes: [.v6]
)
