// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PromptYourself",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "PromptYourself",
            targets: ["PromptYourself"]
        ),
    ],
    targets: [
        .target(
            name: "PromptYourself",
            path: "PromptYourself",
            resources: [
                .process("Assets.xcassets")
            ]
        ),
    ]
)
