// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TuneMate",
    defaultLocalization: "ko",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TuneMateCore", targets: ["TuneMateCore"]),
        .executable(name: "TuneMateApp", targets: ["TuneMateApp"])
    ],
    targets: [
        .target(
            name: "TuneMateCore",
            path: "Sources/TuneMateCore",
            resources: [
                .copy("Resources/dm248-protocol.yaml")
            ]
        ),
        .executableTarget(
            name: "TuneMateApp",
            dependencies: ["TuneMateCore"],
            path: "Sources/TuneMateApp"
        ),
        .testTarget(
            name: "TuneMateCoreTests",
            dependencies: ["TuneMateCore"],
            path: "Tests/TuneMateCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
