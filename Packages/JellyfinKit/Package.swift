// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JellyfinKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "JellyfinKit", targets: ["JellyfinKit"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(name: "JellyfinKit", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(
            name: "JellyfinKitTests",
            dependencies: [
                "JellyfinKit",
                .product(name: "CoreTestSupport", package: "Core"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
