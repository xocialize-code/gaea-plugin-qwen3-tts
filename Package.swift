// swift-tools-version: 6.2
import PackageDescription

// gaea-plugin-qwen3-tts: Alibaba's Qwen3-TTS (Apache-2.0 weights) as a Gaea plugin on MES Audio 0.1. One worker
// executable built on GaeaPluginKit over mlx-qwen3-tts-swift, packaged as a signed .gaeaplugin by
// scripts/build-plugin.sh.
//
// qwen3-inproc is not part of the plugin: it runs the same package in-process through MLXServeEngine, with the same
// dependency resolution, requests and seeding, as the reference a run through Gaea is compared against.
//
// GAEA_PLUGIN_KIT_PATH points the kit at a local checkout while you work on both.
let kitPath = Context.environment["GAEA_PLUGIN_KIT_PATH"]

let package = Package(
    name: "gaea-plugin-qwen3-tts",
    platforms: [.macOS(.v26)], // mlx-engine-swift's MLXToolKit requires macOS 26
    dependencies: [
        kitPath.map { .package(path: $0) }
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.8.0"),
        .package(url: "https://github.com/xocialize/mlx-qwen3-tts-swift.git", exact: "0.7.0"),
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.73.1"),
        // MLX's random state: the talker samples from it, so a seeded run seeds it first.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.33.0"),
    ],
    targets: [
        .target(
            name: "Qwen3Plugin",
            dependencies: [
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
                .product(name: "MLXQwen3TTS", package: "mlx-qwen3-tts-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "gaea-qwen3-tts-worker",
            dependencies: [
                "Qwen3Plugin",
                .product(name: "GaeaPluginKit", package: "gaea-plugin-kit"),
            ]
        ),
        .executableTarget(
            name: "qwen3-inproc",
            dependencies: [
                "Qwen3Plugin",
                .product(name: "GaeaProtocol", package: "gaea-plugin-kit"),
                .product(name: "MLXQwen3TTS", package: "mlx-qwen3-tts-swift"),
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "Qwen3PluginTests", dependencies: ["Qwen3Plugin"]),
    ]
)
