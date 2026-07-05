// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MacCaptureVerifier",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ClientCore", targets: ["ClientCore"]),
        .executable(name: "CaptureCLI", targets: ["CaptureCLI"]),
        .executable(name: "CaptureServer", targets: ["CaptureServer"]),
        .executable(name: "PCMClient", targets: ["PCMClient"]),
        .executable(name: "PCMPlayer", targets: ["PCMPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "CaptureCLI",
            dependencies: ["CaptureCore", "WAV", "Utilities"]
        ),
        .executableTarget(
            name: "CaptureServer",
            dependencies: ["CaptureCore", "Server", "Streaming", "Utilities"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CaptureServer/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "PCMClient",
            dependencies: ["Streaming", "Utilities"]
        ),
        .executableTarget(
            name: "PCMPlayer",
            dependencies: ["ClientCore", "Utilities"]
        ),
        .target(
            name: "ClientCore",
            dependencies: ["Streaming", "Utilities"]
        ),
        .target(
            name: "CaptureCore",
            dependencies: ["WAV", "Utilities", "Streaming"]
        ),
        .target(
            name: "Streaming",
            dependencies: ["Utilities"]
        ),
        .target(
            name: "Server",
            dependencies: ["CaptureCore", "Streaming", "Utilities"]
        ),
        .target(
            name: "WAV",
            dependencies: ["Utilities"]
        ),
        .target(
            name: "Utilities"
        ),
        .testTarget(
            name: "WAVTests",
            dependencies: ["WAV"]
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"]
        ),
        .testTarget(
            name: "StreamingTests",
            dependencies: ["Streaming"]
        ),
        .testTarget(
            name: "PCMPlayerTests",
            dependencies: ["ClientCore"]
        )
    ]
)
