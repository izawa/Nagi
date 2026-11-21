// swift-tools-version: 6.4
// Light under water: caustics on the floor of shallow water (M4-PLAN). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "CausticsEffect",
    defaultLocalization: "ja",
    platforms: [.macOS(.v27)],
    products: [.library(name: "CausticsEffect", targets: ["CausticsEffect"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [
        .target(name: "CausticsEffect", dependencies: ["NagiKit"], resources: [.process("Shaders"), .process("Resources")]),
        .testTarget(name: "CausticsEffectTests", dependencies: ["CausticsEffect", "NagiKit"]),
    ]
)
