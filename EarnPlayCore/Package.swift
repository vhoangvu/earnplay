// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EarnPlayCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "EarnPlayCore", targets: ["EarnPlayCore"])
    ],
    targets: [
        .target(name: "EarnPlayCore"),
        .testTarget(name: "EarnPlayCoreTests", dependencies: ["EarnPlayCore"])
    ]
)
