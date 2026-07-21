// swift-tools-version: 6.1

import PackageDescription

// The package keeps platform front ends thin: shared protocol/session/WebRTC targets are reused by
// the iOS viewer and macOS host, while native audio-device shims are selected conditionally. The
// executable products also serve as deterministic diagnostic tools for the same core libraries.
let package = Package(
    name: "opensteamer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ClientCore", targets: ["ClientCore"]),
        .library(name: "RemoteSessionCore", targets: ["RemoteSessionCore"]),
        .library(name: "Streaming", targets: ["Streaming"]),
        .library(name: "WebRTCTransport", targets: ["WebRTCTransport"]),
        .executable(name: "CaptureCLI", targets: ["CaptureCLI"]),
        .executable(name: "CaptureServer", targets: ["CaptureServer"]),
        .executable(name: "PCMClient", targets: ["PCMClient"]),
        .executable(name: "PCMPlayer", targets: ["PCMPlayer"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/livekit/webrtc-xcframework.git",
            exact: "144.7559.11"
        )
    ],
    targets: [
        .executableTarget(
            name: "CaptureCLI",
            dependencies: ["CaptureCore", "WAV", "Utilities"],
            path: "macOS/Sources/CaptureCLI"
        ),
        .executableTarget(
            name: "CaptureServer",
            dependencies: [
                "CaptureCore",
                "RemoteSessionCore",
                "Server",
                "Streaming",
                "Utilities",
                "WebRTCTransport"
            ],
            path: "macOS/Sources/CaptureServer",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "macOS/Sources/CaptureServer/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "PCMClient",
            dependencies: ["Streaming", "Utilities"],
            path: "macOS/Sources/PCMClient"
        ),
        .executableTarget(
            name: "PCMPlayer",
            dependencies: ["ClientCore", "Utilities"],
            path: "macOS/Sources/PCMPlayer"
        ),
        .target(
            name: "ClientCore",
            dependencies: ["Streaming", "Utilities"],
            path: "shared/Sources/ClientCore"
        ),
        .target(
            name: "CaptureCore",
            dependencies: ["WAV", "Utilities", "Streaming"],
            path: "macOS/Sources/CaptureCore"
        ),
        .target(
            name: "RemoteSessionCore",
            path: "shared/Sources/RemoteSessionCore"
        ),
        .target(
            name: "Streaming",
            dependencies: ["Utilities"],
            path: "shared/Sources/Streaming"
        ),
        .target(
            name: "Server",
            dependencies: ["CaptureCore", "Streaming", "Utilities"],
            path: "macOS/Sources/Server"
        ),
        .target(
            name: "WAV",
            dependencies: ["Utilities"],
            path: "macOS/Sources/WAV"
        ),
        .target(
            name: "Utilities",
            path: "shared/Sources/Utilities"
        ),
        .target(
            name: "WebRTCTransport",
            dependencies: [
                "RemoteSessionCore",
                .target(
                    name: "IOSWebRTCAudioDeviceShim",
                    condition: .when(platforms: [.iOS])
                ),
                .target(
                    name: "MacWebRTCAudioDeviceShim",
                    condition: .when(platforms: [.macOS])
                ),
                .product(
                    name: "LiveKitWebRTC",
                    package: "webrtc-xcframework"
                )
            ],
            path: "shared/Sources/WebRTCTransport"
        ),
        .target(
            name: "MacWebRTCAudioDeviceShim",
            dependencies: [
                .product(
                    name: "LiveKitWebRTC",
                    package: "webrtc-xcframework"
                )
            ],
            path: "shared/Sources/MacWebRTCAudioDeviceShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "IOSWebRTCAudioDeviceShim",
            dependencies: [
                .product(
                    name: "LiveKitWebRTC",
                    package: "webrtc-xcframework"
                )
            ],
            path: "shared/Sources/IOSWebRTCAudioDeviceShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio")
            ]
        ),
        .target(
            name: "MacWebRTCAudioDeviceShimTestSupport",
            dependencies: [
                .target(
                    name: "MacWebRTCAudioDeviceShim",
                    condition: .when(platforms: [.macOS])
                ),
                .product(
                    name: "LiveKitWebRTC",
                    package: "webrtc-xcframework",
                    condition: .when(platforms: [.macOS])
                )
            ],
            path: "shared/Tests/MacWebRTCAudioDeviceShimTestSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox")
            ]
        ),
        .testTarget(
            name: "WAVTests",
            dependencies: ["WAV"],
            path: "macOS/Tests/WAVTests"
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"],
            path: "macOS/Tests/CaptureCoreTests"
        ),
        .testTarget(
            name: "CaptureServerTests",
            dependencies: ["CaptureServer"],
            path: "macOS/Tests/CaptureServerTests"
        ),
        .testTarget(
            name: "StreamingTests",
            dependencies: ["Streaming"],
            path: "shared/Tests/StreamingTests"
        ),
        .testTarget(
            name: "PCMPlayerTests",
            dependencies: ["ClientCore"],
            path: "macOS/Tests/PCMPlayerTests"
        ),
        .testTarget(
            name: "RemoteSessionCoreTests",
            dependencies: ["RemoteSessionCore"],
            path: "shared/Tests/RemoteSessionCoreTests"
        ),
        .testTarget(
            name: "WebRTCTransportTests",
            dependencies: [
                "RemoteSessionCore",
                "WebRTCTransport"
            ],
            path: "shared/Tests/WebRTCTransportTests"
        ),
        .testTarget(
            name: "MacWebRTCAudioDeviceShimTests",
            dependencies: [
                .target(
                    name: "MacWebRTCAudioDeviceShim",
                    condition: .when(platforms: [.macOS])
                ),
                .target(
                    name: "MacWebRTCAudioDeviceShimTestSupport",
                    condition: .when(platforms: [.macOS])
                ),
                .product(
                    name: "LiveKitWebRTC",
                    package: "webrtc-xcframework",
                    condition: .when(platforms: [.macOS])
                )
            ],
            path: "shared/Tests/MacWebRTCAudioDeviceShimTests"
        )
    ]
)
