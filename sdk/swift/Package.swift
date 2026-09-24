// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "micropod-sdk",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "MicropodSDK", targets: ["MicropodSDK"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "MicropodSDK",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
    ]
)
