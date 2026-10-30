// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rill",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RillCore", targets: ["RillCore"]),
        .executable(name: "Rill", targets: ["RillApp"])
    ],
    targets: [
        .target(name: "RillCore"),
        .executableTarget(name: "RillApp", dependencies: ["RillCore"]),
        .testTarget(name: "RillCoreTests", dependencies: ["RillCore"])
    ],
    swiftLanguageModes: [.v5]
)
