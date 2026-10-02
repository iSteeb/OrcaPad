// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OrcaPad",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "OrcaPad",
            targets: ["OrcaPad"]
        ),
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "OrcaPad",
            dependencies: ["Engine"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // Swift↔C++ interop layer over the (future) libslic3r static lib.
        .target(
            name: "Engine",
            dependencies: ["CxxProbe"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // Prebuilt C++ static library (hand-rolled xcframework, built by
        // clang -target arm64-apple-ios from Linux; see Engine/build.sh).
        .binaryTarget(
            name: "CxxProbe",
            path: "Prebuilt/CxxProbe.xcframework"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
