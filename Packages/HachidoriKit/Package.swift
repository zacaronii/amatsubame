// swift-tools-version: 6.2
import PackageDescription

/// A client for Hachidori's Sharing link (github.com/bee-san/hachidori, GPL-3.0): look words up on
/// a Hachidori host, share its lookup counts, known words and personal dictionary, and copy
/// dictionaries to and from it (docs/hachidori.md).
let package = Package(
    name: "HachidoriKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HachidoriKit", targets: ["HachidoriKit"]),
    ],
    dependencies: [
        .package(path: "../Dictionary"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(name: "HachidoriKit", dependencies: [
            .product(name: "Dictionary", package: "Dictionary"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ]),
        .testTarget(
            name: "HachidoriKitTests",
            dependencies: ["HachidoriKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
