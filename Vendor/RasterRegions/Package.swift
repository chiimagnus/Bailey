// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RasterRegions",
    platforms: [.macOS("15.6")],
    products: [.library(name: "RasterRegions", targets: ["RasterRegions"])],
    targets: [
        .target(name: "RasterRegions", path: "Sources", publicHeadersPath: "include",
                cSettings: [.headerSearchPath("libpng"), .headerSearchPath("libtiff")], linkerSettings: [.linkedLibrary("z")]),
    ]
)
