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
        .library(name: "LLM", targets: ["LLM"]),
        .executable(name: "wavepod-resolve", targets: ["wavepod-resolve"]),
        .executable(name: "wavepod-transcribe", targets: ["wavepod-transcribe"]),
        .executable(name: "wavepod-ask", targets: ["wavepod-ask"]),
        .library(name: "Library", targets: ["Library"]),
        .library(name: "Player", targets: ["Player"]),
        .library(name: "UI", targets: ["UI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.29.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.29.3"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", from: "1.18.0"),
    ],
    targets: [
        .target(name: "Networking"),
        .target(name: "Resolver", dependencies: ["Networking"]),
        .target(name: "Engine", dependencies: ["Library", "Networking"]),
        .target(name: "NativeEngine", dependencies: ["Engine", .product(name: "WhisperKit", package: "WhisperKit"), .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "Speakers", dependencies: ["Library"]),
        .target(name: "Pipeline", dependencies: ["LLM", "Engine", "Resolver", "Speakers", "Library", "Networking"]),
        .target(name: "LLM", dependencies: ["Library", "Engine", "Networking", .product(name: "MLX", package: "mlx-swift"), .product(name: "MLXLLM", package: "mlx-swift-lm"), .product(name: "MLXLMCommon", package: "mlx-swift-lm"), .product(name: "MLXEmbedders", package: "mlx-swift-lm")]),
        .testTarget(name: "NativeEngineTests", dependencies: ["NativeEngine", "Pipeline"]),
        .testTarget(name: "PipelineTests", dependencies: ["Pipeline", "Speakers", "LLM", "Networking"]),
        .executableTarget(name: "wavepod-resolve", dependencies: ["Resolver"]),
        // The shipping pipeline, in-process, for eval/podeval.
        .executableTarget(name: "wavepod-transcribe", dependencies: ["NativeEngine", "Pipeline"]),
        // Citation check of the local model on a real transcript (Phase 5 evaluation).
        .executableTarget(name: "wavepod-ask", dependencies: ["LLM", "Library"]),
        .testTarget(name: "ResolverTests", dependencies: ["Resolver"], resources: [.copy("Fixtures")]),
        // Domain models, durable records, and the full-text index.
        .target(name: "Library", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // Playback clock and transport. AVPlayer-backed in the app, simulated in previews and tests.
        .target(name: "Player", dependencies: ["Library"]),
        // SwiftUI views and design tokens.
        .target(name: "UI", dependencies: ["Library", "Player", "Resolver", "Pipeline", "Speakers", "LLM"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(
            name: "UITests",
            dependencies: ["UI", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            exclude: ["__Snapshots__"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
