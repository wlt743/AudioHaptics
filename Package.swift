// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AudioHaptics",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "AudioHaptics", targets: ["AudioHaptics"]),
    ],
    targets: [
        .target(name: "AudioHaptics", path: "Sources/AudioHaptics"),
    ]
)
