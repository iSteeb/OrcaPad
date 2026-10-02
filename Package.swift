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
    targets: [
        .target(
            name: "OrcaPad",
            path: "Sources/OrcaPad"
        ),
    ]
)
