// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "BrowserKit", targets: ["BrowserKit"]),
    ],
    dependencies: [
        .package(path: "../Anki"),
        .package(path: "../AppCommon"),
        .package(path: "../Core"),
        .package(path: "../Dictionary"),
        .package(path: "../Lookup"),
    ],
    targets: [
        .target(name: "BrowserKit", dependencies: [
            .product(name: "Anki", package: "Anki"),
            .product(name: "AppCommon", package: "AppCommon"),
            .product(name: "Core", package: "Core"),
            .product(name: "Dictionary", package: "Dictionary"),
            .product(name: "Lookup", package: "Lookup"),
        ]),
        .testTarget(name: "BrowserKitTests", dependencies: [
            "BrowserKit",
            .product(name: "AppCommon", package: "AppCommon"),
            .product(name: "Core", package: "Core"),
            .product(name: "CoreTestSupport", package: "Core"),
            .product(name: "Lookup", package: "Lookup"),
            .product(name: "Dictionary", package: "Dictionary"),
            .product(name: "DictionaryTestSupport", package: "Dictionary"),
        ]),
    ]
)
