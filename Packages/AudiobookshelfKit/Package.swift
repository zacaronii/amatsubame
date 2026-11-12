// swift-tools-version: 6.2
import PackageDescription

/// Kiku's servers: Audiobookshelf (podcasts, progress) and Kaku (transcripts).
let package = Package(
    name: "AudiobookshelfKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AudiobookshelfKit", targets: ["AudiobookshelfKit"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(name: "AudiobookshelfKit", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(
            name: "AudiobookshelfKitTests",
            dependencies: [
                "AudiobookshelfKit",
                .product(name: "CoreTestSupport", package: "Core"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
