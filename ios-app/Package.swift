// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HeartlabsEcho",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HeartlabsEcho",
            targets: ["HeartlabsEcho"]
        ),
    ],
    targets: [
        .target(
            name: "HeartlabsEcho",
            path: "HeartlabsEcho",
            resources: [
                .process("Assets.xcassets")
            ]
        ),
    ]
)
