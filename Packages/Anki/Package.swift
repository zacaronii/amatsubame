// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Anki",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Anki", targets: ["Anki"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Dictionary"),
    ],
    targets: [
        .target(name: "Anki", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "Dictionary", package: "Dictionary"),
        ]),
        .testTarget(
            name: "AnkiTests",
            dependencies: [
                "Anki",
                .product(name: "CoreTestSupport", package: "Core"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
