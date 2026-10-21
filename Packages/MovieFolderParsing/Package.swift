// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "MovieFolderParsing",
  platforms: [.macOS("26.5")],
  products: [.library(name: "MovieFolderParsing", targets: ["MovieFolderParsing"])],
  targets: [
    .target(name: "MovieFolderParsing", swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
    .testTarget(name: "MovieFolderParsingTests", dependencies: ["MovieFolderParsing"],
                swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")])
  ],
  swiftLanguageModes: [.v6]
)
