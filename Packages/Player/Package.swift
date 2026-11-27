// swift-tools-version: 6.2
import PackageDescription

/// Video playback for Miru: mpv (MPVKit, LGPL build), subtitles, card media.
let package = Package(
    name: "Player",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../../Vendor/libfvad"),
        // The LGPL product only, from the owner's fork: its tag's manifest has no GPL product and
        // takes every binary from the owner's forks of MPVKit's build repos (docs/miru.md ▸ MPVKit).
        .package(url: "https://github.com/zacaronii/MPVKit", exact: "1.1.0-n9.0.2-amatsubame.1"),
    ],
    targets: [
        .target(name: "PlayerKit", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "MPVKit", package: "MPVKit"),
            .product(name: "CFVad", package: "libfvad"),
        ], resources: [.copy("Resources/cacert.pem")]),
        .testTarget(name: "PlayerKitTests", dependencies: ["PlayerKit"], resources: [.copy("Fixtures")]),
    ]
)
