// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Readers",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Readers", targets: ["Readers"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Dictionary"),
        .package(path: "../KavitaKit"),
        .package(path: "../OCR"),
        .package(path: "../Lookup"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(name: "Readers", dependencies: [
            .product(name: "Core", package: "Core"),
            .product(name: "Dictionary", package: "Dictionary"),
            .product(name: "KavitaKit", package: "KavitaKit"),
            .product(name: "OCR", package: "OCR"),
            .product(name: "Lookup", package: "Lookup"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ], resources: [.copy("Book/Web")]),
        .testTarget(name: "ReadersTests", dependencies: [
            "Readers",
            .product(name: "CoreTestSupport", package: "Core"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
    ]
)
