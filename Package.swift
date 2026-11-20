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
            ?? .package(url: "https://github.com/xocialize-code/gaea-plugin-kit.git", from: "0.14.1"),
        .package(url: "https://github.com/xocialize/mlx-qwen3-tts-swift.git", exact: "0.7.0"),
        // mlx-engine-swift 0.82.1, the first on the fleet's mlx-swift 0.33.1.
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.82.1"),
        // MLX's random state: the talker samples from it, so a seeded run seeds it first. The fleet's mlx-swift fork,
        // as mlx-engine-swift 0.82.1 takes it: 0.33.1 is upstream 0.33.0 with the vendored MLX's head-dim-split SDPA
        // routes off, which abort or give wrong attention on M5 (AB-D-0264, AB-R-1009). Naming ml-explore's URL here,
        // as 0.2.1 did, won over the engine's fork and built the unpatched 0.33.0.
        .package(url: "https://github.com/xocialize/mlx-swift", from: "0.33.1"),
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
