// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenAvatar",
    platforms: [
        // macOS 14.4 required for CoreAudio process taps (system-audio capture).
        .macOS("14.4")
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Parakeet (NVIDIA) speech-to-text as CoreML on the Neural Engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // SpeakerKit: pyannote v4 ("community-1") speaker diarization as
        // CoreML — runs the end-of-call speaker pass.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "OpenAvatar",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Sources/OpenAvatar"
        ),
        .testTarget(
            name: "OpenAvatarTests",
            dependencies: [
                "OpenAvatar",
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            path: "Tests/OpenAvatarTests"
        )
    ]
)
