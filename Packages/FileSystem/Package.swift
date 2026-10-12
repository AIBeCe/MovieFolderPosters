// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FileSystem",
    platforms: [.macOS("26.5")],
    products: [.library(name: "FileSystem", targets: ["FileSystem"])],
    targets: [
        .target(name: "FileSystem"),
        .testTarget(name: "FileSystemTests", dependencies: ["FileSystem"])
    ]
)
