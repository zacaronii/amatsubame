// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KavitaKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KavitaKit", targets: ["KavitaKit"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "KavitaKit", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(
            name: "KavitaKitTests",
            dependencies: [
                "KavitaKit",
                .product(name: "CoreTestSupport", package: "Core"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
