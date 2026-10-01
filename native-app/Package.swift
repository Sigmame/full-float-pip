// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FloatVideo",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "FloatVideo",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
