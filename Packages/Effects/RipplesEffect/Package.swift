// swift-tools-version: 6.4
// Ripples spreading on a shallow pool over the screen (M6-PLAN). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "RipplesEffect",
    defaultLocalization: "ja",
    platforms: [.macOS(.v27)],
    products: [.library(name: "RipplesEffect", targets: ["RipplesEffect"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [
        .target(name: "RipplesEffect", dependencies: ["NagiKit"], resources: [.process("Shaders"), .process("Resources")]),
        .testTarget(name: "RipplesEffectTests", dependencies: ["RipplesEffect", "NagiKit"]),
    ]
)
