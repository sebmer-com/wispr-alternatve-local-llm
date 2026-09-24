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
            .upToNextMinor(from: "0.17.3")
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
        .testTarget(
            name: "FluidPushToTalkTests",
            dependencies: ["FluidPushToTalk"],
            path: "Tests"
        ),
    ]
)
