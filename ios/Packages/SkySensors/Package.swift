// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SkySensors",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SkySensors", targets: ["SkySensors"]),
    ],
    dependencies: [
        .package(path: "../SkyCore"),
    ],
    targets: [
        .target(name: "SkySensors", dependencies: ["SkyCore"]),
        .testTarget(name: "SkySensorsTests", dependencies: ["SkySensors"]),
    ]
)
