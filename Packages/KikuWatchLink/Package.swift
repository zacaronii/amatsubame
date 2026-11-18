// swift-tools-version: 6.2
import PackageDescription

/// What Kiku on the iPhone and Kiku on Apple Watch say to each other over WatchConnectivity:
/// the playing state, commands and their replies (docs/watch.md).
let package = Package(
    name: "KikuWatchLink",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "KikuWatchLink", targets: ["KikuWatchLink"]),
    ],
    targets: [
        .target(name: "KikuWatchLink"),
        .testTarget(name: "KikuWatchLinkTests", dependencies: ["KikuWatchLink"]),
    ]
)
