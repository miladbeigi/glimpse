// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Glimpse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glimpse",
            path: "Sources/Glimpse",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "GlimpseTests",
            dependencies: ["Glimpse"],
            path: "Tests/GlimpseTests"
        ),
    ]
)
