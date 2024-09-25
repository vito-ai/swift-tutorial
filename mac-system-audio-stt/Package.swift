// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "mac-system-audio-stt",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift", from: "1.23.0"),
    ],
    targets: [
        .executableTarget(
            name: "mac-system-audio-stt",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift")
            ],
            resources: [
                .process("Resources/")
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
