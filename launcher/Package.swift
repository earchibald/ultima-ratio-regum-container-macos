// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "URRLauncher",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "URRLauncher", targets: ["URRLauncher"]),
        .executable(name: "urrctl", targets: ["urrctl"]),
    ],
    targets: [
        .target(name: "URRCore"),
        .executableTarget(name: "URRLauncher", dependencies: ["URRCore"]),
        .executableTarget(name: "urrctl", dependencies: ["URRCore"]),
        .testTarget(name: "URRCoreTests", dependencies: ["URRCore"]),
    ],
    swiftLanguageModes: [.v5]
)
