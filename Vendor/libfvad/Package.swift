// swift-tools-version: 6.2
// Added for this project (upstream builds with autotools/CMake); see VENDORED.md.
import PackageDescription

let package = Package(
    name: "libfvad",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CFVad", targets: ["CFVad"]),
    ],
    targets: [
        .target(
            name: "CFVad",
            path: ".",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
    ]
)
