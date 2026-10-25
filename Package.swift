// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
            dependencies: ["OrcaBridge"],
            resources: [
                // OrcaSlicer profiles (JSON-only; pin in profile-source.json).
                // data_dir() points here — PresetBundle reads <dir>/system/…
                .copy("Resources")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // Typed Swift facade over the sole engine-facing Bridge C ABI.
        .target(
            name: "OrcaBridge",
            dependencies: ["OrcaBridgeCore"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // Untouched upstream engine + C++ Bridge boundary, cross-built by
        // Bridge/build-core.sh and packaged as a static xcframework.
        .binaryTarget(
            name: "OrcaBridgeCore",
            path: "Prebuilt/OrcaBridgeCore.xcframework"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
