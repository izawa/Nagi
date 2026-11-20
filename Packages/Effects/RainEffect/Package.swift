// swift-tools-version: 6.4
// Rain on the glass (SPEC 4.2). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "RainEffect",
    defaultLocalization: "ja",
    platforms: [.macOS(.v27)],
    products: [.library(name: "RainEffect", targets: ["RainEffect"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [
        .target(name: "RainEffect", dependencies: ["NagiKit"], resources: [.process("Shaders"), .process("Resources")]),
        .testTarget(name: "RainEffectTests", dependencies: ["RainEffect", "NagiKit"]),
    ]
)
