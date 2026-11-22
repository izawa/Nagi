// swift-tools-version: 6.4
// Gems on the edges of windows left still (M5-PLAN). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "GemsEffect",
    defaultLocalization: "ja",
    platforms: [.macOS(.v27)],
    products: [.library(name: "GemsEffect", targets: ["GemsEffect"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [
        .target(name: "GemsEffect", dependencies: ["NagiKit"], resources: [.process("Shaders"), .process("Resources")]),
        .testTarget(name: "GemsEffectTests", dependencies: ["GemsEffect", "NagiKit"]),
    ]
)
