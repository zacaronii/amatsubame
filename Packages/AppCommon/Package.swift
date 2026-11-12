// swift-tools-version: 6.2
import PackageDescription

/// What every app shares: the common services (database, outbox, dictionaries, lookup,
/// mining) and the screens built on them (dictionaries, audio, Anki, queue, search).
let package = Package(
    name: "AppCommon",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AppCommon", targets: ["AppCommon"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Dictionary"),
        .package(path: "../Lookup"),
        .package(path: "../Anki"),
        .package(path: "../AudiobookshelfKit"),
        .package(path: "../KechimochiKit"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "AppCommon",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "Dictionary", package: "Dictionary"),
                .product(name: "Lookup", package: "Lookup"),
                .product(name: "Anki", package: "Anki"),
                .product(name: "AudiobookshelfKit", package: "AudiobookshelfKit"),
                .product(name: "KechimochiKit", package: "KechimochiKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // Like the app targets, so screens moved here keep their main-actor assumptions.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "AppCommonTests", dependencies: [
            "AppCommon",
            .product(name: "CoreTestSupport", package: "Core"),
            .product(name: "DictionaryTestSupport", package: "Dictionary"),
        ]),
    ]
)
