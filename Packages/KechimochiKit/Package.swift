// swift-tools-version: 6.2
import PackageDescription

/// kechimochi (github.com/Morgawr/kechimochi), an immersion tracker: its dashboard,
/// read only, for Stats ▸ All immersion.
let package = Package(
    name: "KechimochiKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KechimochiKit", targets: ["KechimochiKit"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(name: "KechimochiKit", dependencies: [
            .product(name: "Core", package: "Core"),
        ]),
        .testTarget(
            name: "KechimochiKitTests",
            dependencies: [
                "KechimochiKit",
                .product(name: "CoreTestSupport", package: "Core"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
