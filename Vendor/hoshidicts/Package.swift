// swift-tools-version: 6.2
// Patched from upstream; see VENDORED.md.
import PackageDescription

let package = Package(
    name: "hoshidicts",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "CHoshiDicts", targets: ["CHoshiDicts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
    ],
    targets: [
        .target(
            name: "CHoshiDicts",
            dependencies: [
                .product(name: "libzstd", package: "zstd"),
            ],
            path: ".",
            sources: [
                "src",
                "external/libdeflate/lib",
                "external/utf8proc/utf8proc.c",
                "external/lzokay/lzokay.cpp",
                "external/gumbo-parser/src",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("external/libdeflate"),
                .headerSearchPath("external/libdeflate/lib"),
                .headerSearchPath("external/utfcpp/source"),
                .headerSearchPath("external/glaze/include"),
                .headerSearchPath("external/xxHash"),
                .headerSearchPath("external/unordered_dense/include"),
                .headerSearchPath("external/utf8proc"),
                .headerSearchPath("external/lzokay"),
                .headerSearchPath("external/gumbo-parser/src"),
                .unsafeFlags(["-Wno-missing-braces"]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx2b
)
