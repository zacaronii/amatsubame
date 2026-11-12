// swift-tools-version: 6.2
import PackageDescription

/// Jimaku (jimaku.cc), a library of Japanese subtitles for anime, and the AniDB → AniList
/// id mapping used to find a show there.
let package = Package(
    name: "JimakuKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "JimakuKit", targets: ["JimakuKit"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(name: "JimakuKit", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
        .testTarget(
            name: "JimakuKitTests",
            dependencies: [
                "JimakuKit",
                .product(name: "CoreTestSupport", package: "Core"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
