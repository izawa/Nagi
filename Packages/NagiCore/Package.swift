// swift-tools-version: 6.4
// NagiCore: the engine. Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "NagiCore",
    platforms: [.macOS(.v27)],
    products: [.library(name: "NagiCore", targets: ["NagiCore"])],
    dependencies: [.package(path: "../NagiKit")],
    targets: [
        .target(name: "NagiCore", dependencies: ["NagiKit"], resources: [.process("Shaders")]),
        .testTarget(name: "NagiCoreTests", dependencies: ["NagiCore", "NagiKit"], resources: [.process("Shaders")]),
    ]
)
