// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeoDrop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NeoDropCore", targets: ["NeoDropCore"]),
        .executable(name: "NeoDrop", targets: ["NeoDrop"]),
    ],
    targets: [
        // The Finder badge format, on its own so the Finder Sync extension can be compiled against
        // it without the engine: the extension is a separate bundle that SwiftPM does not build (see
        // scripts/package.sh), and this target is what both sides share.
        .target(
            name: "NeoDropShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "NeoDropCore",
            dependencies: ["NeoDropShared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NeoDrop",
            dependencies: ["NeoDropCore", "NeoDropShared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NeoDropCoreTests",
            dependencies: ["NeoDropCore", "NeoDropShared"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
