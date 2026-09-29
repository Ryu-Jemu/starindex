// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SkyCore",
    platforms: [.iOS("26.0"), .macOS("15.0")],
    products: [
        .library(name: "SkyCore", targets: ["SkyCore"]),
    ],
    targets: [
        // Astronomy Engine v2.1.19 (MIT, Don Cross), vendored at commit 61dc070.
        .target(
            name: "CAstronomy",
            exclude: ["LICENSE", "UPSTREAM_COMMIT"]
        ),
        .target(
            name: "SkyCore",
            dependencies: ["CAstronomy"]
        ),
        .testTarget(
            name: "SkyCoreTests",
            dependencies: ["SkyCore"]
        ),
    ]
)
