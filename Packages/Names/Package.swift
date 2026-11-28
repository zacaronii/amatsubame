// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Names",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Names", targets: ["Names"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Dictionary"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(name: "Names", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "Dictionary", package: "Dictionary"),
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
        .testTarget(
            name: "NamesTests",
            dependencies: [
                "Names",
                .product(name: "CoreTestSupport", package: "Core"),
                .product(name: "DictionaryTestSupport", package: "Dictionary"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
