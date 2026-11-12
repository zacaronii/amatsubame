// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lookup",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Lookup", targets: ["Lookup"]),
    ],
    dependencies: [
        .package(path: "../Anki"),
        .package(path: "../Core"),
        .package(path: "../Dictionary"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "Lookup",
            dependencies: [
                .product(name: "Anki", package: "Anki"),
                .product(name: "Core", package: "Core"),
                .product(name: "Dictionary", package: "Dictionary"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [.copy("Web")]
        ),
        .testTarget(name: "LookupTests", dependencies: [
            "Lookup",
            .product(name: "CoreTestSupport", package: "Core"),
            .product(name: "DictionaryTestSupport", package: "Dictionary"),
        ]),
    ]
)
