// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SleepSkip",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SleepSkipCore", targets: ["SleepSkipCore"]),
        .executable(name: "SleepSkip", targets: ["SleepSkip"])
    ],
    targets: [
        .target(
            name: "SleepSkipCore",
            path: "Sources/SleepSkipCore"
        ),
        .executableTarget(
            name: "SleepSkip",
            dependencies: ["SleepSkipCore"],
            path: "Sources/SleepSkip"
        ),
        .testTarget(
            name: "SleepSkipTests",
            dependencies: ["SleepSkipCore"],
            path: "Tests/SleepSkipTests"
        )
    ]
)
