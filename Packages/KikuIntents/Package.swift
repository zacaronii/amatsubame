// swift-tools-version: 6.2
import PackageDescription

/// What Kiku shares with its widgets and controls: the snapshot they show (written by the app
/// to the App Group) and the intents they run ("Resume in Kiku", "Mark What I Just Heard"),
/// which run inside the app.
let package = Package(
    name: "KikuIntents",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KikuIntents", targets: ["KikuIntents"]),
    ],
    targets: [
        .target(name: "KikuIntents"),
        .testTarget(name: "KikuIntentsTests", dependencies: ["KikuIntents"]),
    ]
)
