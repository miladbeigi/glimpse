// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Glimpse",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned: 0.13.7+ changed AsrManager.transcribe(_:source:) to take an inout decoder state.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.13.5"),
    ],
    targets: [
        // Meeting detection signals (camera, WebRTC traffic, meeting windows, voice activity).
        .target(
            name: "MeetingDetection",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MeetingDetection"
        ),
        // Meeting recording and transcription.
        .target(
            name: "Meetings",
            dependencies: ["MeetingDetection", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Meetings",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Glimpse",
            dependencies: ["Meetings"],
            path: "Sources/Glimpse",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "MeetingsTests",
            dependencies: ["Meetings"],
            path: "Tests/MeetingsTests"
        ),
        .testTarget(
            name: "MeetingDetectionTests",
            dependencies: ["MeetingDetection"],
            path: "Tests/MeetingDetectionTests"
        ),
        .testTarget(
            name: "GlimpseTests",
            dependencies: ["Glimpse"],
            path: "Tests/GlimpseTests"
        ),
    ]
)
