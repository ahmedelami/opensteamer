// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicDbMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MicDbMenu", targets: ["MicDbMenu"])],
    targets: [
        .target(name: "MicDbMenuCore"),
        .executableTarget(name: "MicDbMenu", dependencies: ["MicDbMenuCore"]),
        .testTarget(name: "MicDbMenuCoreTests", dependencies: ["MicDbMenuCore"]),
    ],
    swiftLanguageModes: [.v5]
)
