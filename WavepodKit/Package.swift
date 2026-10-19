// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WavepodKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Resolver", targets: ["Resolver"]),
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "NativeEngine", targets: ["NativeEngine"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
        .executable(name: "wavepod-resolve", targets: ["wavepod-resolve"]),
        .executable(name: "wavepod-transcribe", targets: ["wavepod-transcribe"]),
        .library(name: "Library", targets: ["Library"]),
        .library(name: "Player", targets: ["Player"]),
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.18.0"),
    ],
    targets: [
        .target(name: "Networking"),
        .target(name: "Resolver", dependencies: ["Networking"]),
        .target(name: "Engine", dependencies: ["Library", "Networking"]),
        .target(name: "NativeEngine", dependencies: ["Engine", .product(name: "WhisperKit", package: "WhisperKit"), .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "Pipeline", dependencies: ["Engine", "Resolver", "Library", "Networking"]),
        .testTarget(name: "NativeEngineTests", dependencies: ["NativeEngine", "Pipeline"]),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline", "Networking"]),
        .executableTarget(name: "wavepod-resolve", dependencies: ["Resolver"]),
        // The shipping pipeline, in-process, for eval/podeval.
        .executableTarget(name: "wavepod-transcribe", dependencies: ["NativeEngine", "Pipeline"]),
        .testTarget(name: "ResolverTests", dependencies: ["Resolver"], resources: [.copy("Fixtures")]),
        // Domain models, durable records, and the full-text index.
        .target(name: "Library", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Playback clock and transport. AVPlayer-backed in the app, simulated in previews and tests.
        .target(name: "Player", dependencies: ["Library"]),
        // SwiftUI views and design tokens.
        .target(name: "UI", dependencies: ["Library", "Player", "Resolver", "Pipeline"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(
            name: "UITests",
            dependencies: ["UI", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
