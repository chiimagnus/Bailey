// swift-tools-version:6.2

import PackageDescription

let package = Package(
    name: "SwiftDraw",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SwiftDraw", targets: ["SwiftDraw"])],
    targets: [
        .target(
            name: "SwiftDraw",
            dependencies: ["SwiftDrawDOM"],
            path: "SwiftDraw/Sources",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("ImmutableWeakCaptures"),
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(name: "SwiftDrawDOM", path: "DOM/Sources"),
    ]
)
