// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenAvatar",
    platforms: [
        // macOS 14.4 required for CoreAudio process taps (system-audio capture).
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "OpenAvatar",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/OpenAvatar"
        ),
        .testTarget(
            name: "OpenAvatarTests",
            dependencies: ["OpenAvatar"],
            path: "Tests/OpenAvatarTests"
        )
    ]
)
