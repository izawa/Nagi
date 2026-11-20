// swift-tools-version: 6.4
// Moss on the edges of windows left still (SPEC 4.3). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "MossEffect",
    defaultLocalization: "ja",
    platforms: [.macOS(.v27)],
    products: [.library(name: "MossEffect", targets: ["MossEffect"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [
        .target(name: "MossEffect", dependencies: ["NagiKit"], resources: [.process("Shaders"), .process("Resources")]),
        .testTarget(name: "MossEffectTests", dependencies: ["MossEffect", "NagiKit"]),
    ]
)
