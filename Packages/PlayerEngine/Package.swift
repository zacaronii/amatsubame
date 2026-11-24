// swift-tools-version: 6.2
import PackageDescription

/// What Miru asks of a video engine (spike: mpv and AetherEngine side by side). No FFmpeg in
/// here, so the AetherEngine bridge can depend on it without pulling in MPVKit's static FFmpeg.
let package = Package(
    name: "PlayerEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PlayerEngine", targets: ["PlayerEngine"])],
    targets: [.target(name: "PlayerEngine")]
)
