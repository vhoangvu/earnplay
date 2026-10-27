// swift-tools-version: 6.0
import PackageDescription
import Foundation

// T0.2: the llama.cpp framework is fetched by Scripts/setup-model-spike.sh
// into Frameworks/ (gitignored, ~380 MB unpacked). When it is absent —
// a clean checkout, or CI before setup — the package still builds: the
// CLlamaShim target is simply omitted and ModelRuntime reports
// .runtimeUnavailable. No stub inference is ever compiled in.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasLlamaFramework = FileManager.default.fileExists(
    atPath: packageDir + "/Frameworks/llama.xcframework"
)

var earnPlayCoreDeps: [Target.Dependency] = []
var extraTargets: [Target] = []
if hasLlamaFramework {
    earnPlayCoreDeps.append("CLlamaShim")
    extraTargets.append(contentsOf: [
        .binaryTarget(name: "llama", path: "Frameworks/llama.xcframework"),
        .target(name: "CLlamaShim", dependencies: ["llama"]),
    ])
}

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
        .target(name: "EarnPlayCore", dependencies: earnPlayCoreDeps),
        .testTarget(name: "EarnPlayCoreTests", dependencies: ["EarnPlayCore"])
    ] + extraTargets
)
