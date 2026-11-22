// swift-tools-version: 6.4
// The Nagi app and the effect registration list (SPEC 3.2). The .app is assembled by scripts/build-app.sh.
import PackageDescription

let package = Package(
    name: "NagiApp",
    defaultLocalization: "ja",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Nagi", targets: ["Nagi"]),
        .library(name: "EffectCatalog", targets: ["EffectCatalog"]),
    ],
    dependencies: [
        .package(path: "../Packages/NagiKit"),
        .package(path: "../Packages/NagiCore"),
        .package(path: "../Packages/Effects/KomorebiEffect"),
        .package(path: "../Packages/Effects/RainEffect"),
        .package(path: "../Packages/Effects/MossEffect"),
        .package(path: "../Packages/Effects/CausticsEffect"),
        .package(path: "../Packages/Effects/GemsEffect"),
        .package(path: "../Packages/Effects/DebugEffects"),
    ],
    targets: [
        // Adding an effect: one package, plus one line in EffectCatalog (SPEC 3.2).
        .target(name: "EffectCatalog", dependencies: ["NagiKit", "KomorebiEffect", "RainEffect", "MossEffect", "CausticsEffect", "GemsEffect"]),
        .executableTarget(
            name: "Nagi",
            dependencies: ["NagiKit", "NagiCore", "EffectCatalog", "DebugEffects"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "NagiTests", dependencies: ["Nagi", "NagiKit", "EffectCatalog"]),
    ]
)
