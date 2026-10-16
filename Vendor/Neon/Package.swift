// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "Neon",
    platforms: [.macOS("14.0")],
    products: [.library(name: "Neon", targets: ["Neon"])],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
        .package(url: "https://github.com/ChimeHQ/Rearrange", from: "1.6.0"),
    ],
    targets: [
        .target(name: "Neon", dependencies: ["SwiftTreeSitter", "Rearrange", "TreeSitterClient"],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "TreeSitterClient", dependencies: ["Rearrange", "SwiftTreeSitter"]),
    ]
)
