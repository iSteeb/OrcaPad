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
            resources: [
                // OrcaSlicer system profiles (JSON-only subset, upstream tag).
                // data_dir() points here — PresetBundle reads <dir>/system/…
                .copy("Resources")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // Swift↔C++ interop layer over the OrcaSlicer engine static lib.
        .target(
            name: "Engine",
            dependencies: ["OrcaCore"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // libslic3r geometry subset (built by Engine/build-core.sh —
        // clang -target arm64-apple-ios from Linux, static archive).
        .binaryTarget(
            name: "OrcaCore",
            path: "Prebuilt/OrcaCore.xcframework"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
