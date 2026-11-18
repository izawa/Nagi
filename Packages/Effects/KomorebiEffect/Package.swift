// swift-tools-version: 6.4
// Komorebi (SPEC 4.1). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "KomorebiEffect",
    platforms: [.macOS(.v27)],
    products: [.library(name: "KomorebiEffect", targets: ["KomorebiEffect"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [
        .target(name: "KomorebiEffect", dependencies: ["NagiKit"], resources: [.process("Shaders")]),
        .testTarget(name: "KomorebiEffectTests", dependencies: ["KomorebiEffect"]),
    ]
)
