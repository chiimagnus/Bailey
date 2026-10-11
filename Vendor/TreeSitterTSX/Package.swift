// swift-tools-version: 5.10

import PackageDescription

// The tree-sitter TSX grammar (TypeScript + JSX), vendored so kero can link it.
// 本地包的原因与更新规则见 ../../docs/DEPENDENCIES.md。
let package = Package(
    name: "TreeSitterTSX",
    products: [
        .library(name: "TreeSitterTSX", targets: ["TreeSitterTSX"])
    ],
    targets: [
        .target(name: "TreeSitterTSX", cSettings: [.headerSearchPath("src")])
    ]
)
