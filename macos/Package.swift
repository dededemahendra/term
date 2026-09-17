// swift-tools-version: 5.9
import PackageDescription
import Foundation

// The Rust core is built into ../target/release by scripts/build-core.sh.
// A fat archive in ../target/universal (from build-core.sh --universal)
// takes precedence so release builds can target both architectures.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let universalDir = packageRoot.appendingPathComponent("../target/universal").standardized.path
let releaseDir = packageRoot.appendingPathComponent("../target/release").standardized.path
let coreLibDir = FileManager.default.fileExists(atPath: universalDir + "/libtermcore.a") ? universalDir : releaseDir

let package = Package(
    name: "Term",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CTermCore",
            path: "Sources/CTermCore",
            linkerSettings: [.unsafeFlags(["-L", coreLibDir]), .linkedLibrary("termcore")]
        ),
        .target(name: "CPty", path: "Sources/CPty"),
        .target(name: "TermKit", dependencies: ["CTermCore", "CPty"], path: "Sources/TermKit"),
        .executableTarget(name: "Term", dependencies: ["TermKit"], path: "Sources/Term"),
        .testTarget(name: "TermKitTests", dependencies: ["TermKit"], path: "Tests/TermKitTests"),
    ]
)
