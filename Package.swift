// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Micropod",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "MicropodCore", targets: ["MicropodCore"]),
        .executable(name: "MicropodApp", targets: ["MicropodApp"]),
        .executable(name: "MicropodMCP", targets: ["MicropodMCP"]),
        .executable(name: "MicropodBench", targets: ["MicropodBench"]),
        .executable(name: "MicropodAPI", targets: ["MicropodAPI"]),
        .executable(name: "micropod", targets: ["MicropodCLI"]),
        .executable(name: "micropod-docker-shim", targets: ["MicropodDockerShim"]),
        .executable(name: "micropod-sharedfs", targets: ["MicropodSharedFSDaemon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
        // Native-runtime integration: the installed `container` 1.3.1 runtime
        // ships vminit 0.42.0; pin exactly so the generated SandboxContext
        // stubs match the guest agent on the wire.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.42.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .target(
            name: "CPtyShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MicropodCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Yams", package: "Yams"),
                "CPtyShim",
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MicropodApp",
            dependencies: [
                "MicropodCore",
                "MicropodRuntime",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/micropod-mark.png"),
                .copy("Resources/icons"),
                .copy("Resources/brandbrain"),
                .process("Localizable.xcstrings"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "MicropodRuntime",
            dependencies: [
                "MicropodCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MicropodMCP",
            dependencies: ["MicropodCore", "MicropodSharedFS"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MicropodAPI",
            dependencies: ["MicropodCore", "MicropodRuntime"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MicropodCLI",
            dependencies: ["MicropodCore", "MicropodSharedFS", "MicropodRuntime"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MicropodDockerShim",
            dependencies: ["MicropodCore", "MicropodSharedFS", "MicropodRuntime"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MicropodBench",
            dependencies: ["MicropodCore", "MicropodRuntime"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "MicropodSharedFS",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "MicropodSharedFSDaemon",
            dependencies: ["MicropodCore", "MicropodSharedFS"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MicropodRuntimeTests",
            dependencies: ["MicropodRuntime", "MicropodCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MicropodSharedFSTests",
            dependencies: ["MicropodSharedFS"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MicropodCoreTests",
            dependencies: ["MicropodCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MicropodAppTests",
            dependencies: ["MicropodApp", "MicropodCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MicropodIntegrationTests",
            dependencies: ["MicropodCore", "MicropodSharedFS"],
            exclude: ["Support", "Fixtures"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MicropodDockerShimTests",
            dependencies: ["MicropodCore", "MicropodDockerShim", "MicropodSharedFS"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
    ]
)
