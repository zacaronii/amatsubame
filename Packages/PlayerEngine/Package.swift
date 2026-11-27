// swift-tools-version: 6.2
import PackageDescription

/// What Miru's player asks of a video engine (docs/AETHER_PLAN.md). No FFmpeg in here: PlayerKit
/// (mpv) and the AetherEngine bridge both depend on it, and the bridge mustn't pull in MPVKit's
/// static FFmpeg next to AetherEngine's own.
let package = Package(
    name: "PlayerEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PlayerEngine", targets: ["PlayerEngine"])],
    targets: [
        .target(name: "PlayerEngine"),
        .testTarget(name: "PlayerEngineTests", dependencies: ["PlayerEngine"]),
    ]
)
