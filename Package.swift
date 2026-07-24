// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveTennisApi",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "LiveTennisApi", targets: ["LiveTennisApi"])
    ],
    targets: [
        .target(name: "LiveTennisApi"),
        .testTarget(
            name: "LiveTennisApiTests",
            dependencies: ["LiveTennisApi"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
