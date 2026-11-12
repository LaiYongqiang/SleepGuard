// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SleepGuard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SleepGuardCore", targets: ["SleepGuardCore"]),
        .executable(name: "SleepGuard", targets: ["SleepGuard"])
    ],
    targets: [
        .target(
            name: "SleepGuardCore",
            path: "Sources/SleepGuardCore"
        ),
        .executableTarget(
            name: "SleepGuard",
            dependencies: ["SleepGuardCore"],
            path: "Sources/SleepGuard"
        ),
        .testTarget(
            name: "SleepGuardTests",
            dependencies: ["SleepGuardCore"],
            path: "Tests/SleepGuardTests"
        )
    ]
)
