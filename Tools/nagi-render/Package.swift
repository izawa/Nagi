// swift-tools-version: 6.4
// nagi-render: renders effects off screen to PNG (SPEC 3.12).
import PackageDescription

let package = Package(
    name: "nagi-render",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(path: "../../Packages/NagiKit"),
        .package(path: "../../Packages/NagiCore"),
        .package(path: "../../App"),
        .package(path: "../../Packages/Effects/DebugEffects"),
    ],
    targets: [
        .executableTarget(name: "nagi-render", dependencies: [
            "NagiKit", "NagiCore", "DebugEffects", .product(name: "EffectCatalog", package: "App"),
        ]),
    ]
)
