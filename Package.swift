// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rill",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RillCore", targets: ["RillCore"]),
        .executable(name: "rill", targets: ["RillApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "RillCore"),
        .executableTarget(name: "RillApp", dependencies: ["RillCore", .product(name: "Sparkle", package: "Sparkle")]),
        .target(name: "RillTestSupport", dependencies: ["RillCore"], path: "Tests/Support"),
        .testTarget(name: "RillCoreTests", dependencies: ["RillCore", "RillTestSupport"]),
        .testTarget(name: "RillAppTests", dependencies: ["RillApp", "RillTestSupport"])
    ],
    swiftLanguageModes: [.v5]
)
