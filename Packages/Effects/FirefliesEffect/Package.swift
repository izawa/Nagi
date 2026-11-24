// swift-tools-version: 6.4
// Fireflies: lights flying beyond the screen at night (M7-PLAN). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "FirefliesEffect",
    defaultLocalization: "ja",
    platforms: [.macOS(.v27)],
    products: [.library(name: "FirefliesEffect", targets: ["FirefliesEffect"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [
        .target(name: "FirefliesEffect", dependencies: ["NagiKit"], resources: [.process("Shaders"), .process("Resources")]),
        .testTarget(name: "FirefliesEffectTests", dependencies: ["FirefliesEffect", "NagiKit"]),
    ]
)
