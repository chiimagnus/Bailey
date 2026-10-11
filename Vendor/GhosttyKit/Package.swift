// swift-tools-version: 6.0
import PackageDescription

// Keep the upstream Swift sources as a submodule; only the large binary is local.
let package = Package(
    name: "GhosttyKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", from: "2.1.0"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal"
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(name: "libghostty", path: "BinaryTarget/GhosttyKit.xcframework"),
    ]
)
