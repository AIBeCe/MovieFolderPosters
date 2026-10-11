// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Network",
    platforms: [.macOS("26.5")],
    products: [.library(name: "Network", targets: ["Network"])],
    targets: [
        .target(name: "Network"),
        .testTarget(name: "NetworkTests", dependencies: ["Network"])
    ],
    swiftLanguageModes: [.v6]
)
