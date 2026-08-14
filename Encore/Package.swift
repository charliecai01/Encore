// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        // Exposed so the iOS app (a separate Xcode project) can link the
        // shared core. Without an explicit product, only the package's own
        // targets can use EncoreCore.
        .library(name: "EncoreCore", targets: ["EncoreCore"]),
    ],
    targets: [
        .target(
            name: "EncoreCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Encore",
            dependencies: ["EncoreCore"],
            path: "macOS",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "encore-smoke",
            dependencies: ["EncoreCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Create/rotate the "R&B by Sonnet5" generated playlist. Needs a real
        // account cookie (see main.swift) — not part of the shipped apps.
        .executableTarget(
            name: "encore-playlist-tool",
            dependencies: ["EncoreCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Shared-core unit tests. EncoreCore is the brain both the macOS and
        // iOS apps link, so these cover logic for both platforms. Run: swift test
        .testTarget(
            name: "EncoreCoreTests",
            dependencies: ["EncoreCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
