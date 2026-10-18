// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WavepodKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Library", targets: ["Library"]),
        .library(name: "Player", targets: ["Player"]),
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.18.0"),
    ],
    targets: [
        // Domain model: episodes, transcripts, speakers, chapters, chat. Persistence (GRDB) lands here in Phase 5.
        .target(name: "Library"),
        // Playback clock and transport. AVPlayer-backed in the app, simulated in previews and tests.
        .target(name: "Player", dependencies: ["Library"]),
        // SwiftUI views and design tokens.
        .target(name: "UI", dependencies: ["Library", "Player"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(
            name: "UITests",
            dependencies: ["UI", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
