// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FluidAudioPushToTalk",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "fluid-push-to-talk",
            targets: ["FluidPushToTalk"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            branch: "main"
        ),
    ],
    targets: [
        .executableTarget(
            name: "FluidPushToTalk",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        ),
    ]
)
