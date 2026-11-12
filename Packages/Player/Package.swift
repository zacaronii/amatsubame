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
        // The LGPL product only ("MPVKit", never "MPVKit-GPL").
        .package(url: "https://github.com/mpvkit/MPVKit", exact: "1.1.0-n9.0.2"),
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
