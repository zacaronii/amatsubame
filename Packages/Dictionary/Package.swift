// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dictionary",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Dictionary", targets: ["Dictionary"]),
        .library(name: "DictionaryTestSupport", targets: ["DictionaryTestSupport"]),
        .executable(name: "dictionary-prebuild", targets: ["dictionary-prebuild"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../../Vendor/hoshidicts"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "Dictionary", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "CHoshiDicts", package: "hoshidicts"),
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "DictionaryTestSupport", dependencies: ["Dictionary"]),
        // Mac tool: prebuilds dictionaries for the Safari extension (scripts/prebuild-extension-dictionaries.sh).
        .executableTarget(name: "dictionary-prebuild", dependencies: ["Dictionary"]),
        .testTarget(
            name: "DictionaryTests",
            dependencies: ["Dictionary", "DictionaryTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
