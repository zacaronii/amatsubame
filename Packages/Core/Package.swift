// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "CoreTestSupport", targets: ["CoreTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "Core", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "CoreTestSupport", dependencies: ["Core"]),
        .testTarget(name: "CoreTests", dependencies: ["Core", "CoreTestSupport"]),
    ]
)
