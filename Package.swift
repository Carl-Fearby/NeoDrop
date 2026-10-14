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
        .target(
            name: "NeoDropCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NeoDrop",
            dependencies: ["NeoDropCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NeoDropCoreTests",
            dependencies: ["NeoDropCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
