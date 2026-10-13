// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VebeVoice",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        // Pinned to a frozen commit: dependency branch movement cannot reach this build.
        .package(url: "https://github.com/altic-dev/FluidAudio.git", revision: "edee7154e66d2196be896580c6c26ff81c2c528e"),
        .package(url: "https://github.com/altic-dev/transcribe-cpp-swift.git", exact: "0.1.2"),
    ],
    targets: [
        .target(
            name: "CoreAudioCaptureSupport",
            path: "Sources/CoreAudioCaptureSupport",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
            ]
        ),
        .executableTarget(
            name: "VebeVoice",
            dependencies: [
                "CoreAudioCaptureSupport",
                "FluidAudio",
                .product(name: "TranscribeCpp", package: "transcribe-cpp-swift"),
            ]
        ),
    ]
)
