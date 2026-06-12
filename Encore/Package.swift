// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Encore",
    platforms: [.macOS(.v15), .iOS(.v17)],
    targets: [
        .target(
            name: "EncoreCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Encore",
            dependencies: ["EncoreCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "encore-smoke",
            dependencies: ["EncoreCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
