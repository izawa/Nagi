// swift-tools-version: 6.4
// Effects for calibration and debugging (M1-PLAN 7.1). Depends on NagiKit only (SPEC 3.2).
import PackageDescription

let package = Package(
    name: "DebugEffects",
    platforms: [.macOS(.v27)],
    products: [.library(name: "DebugEffects", targets: ["DebugEffects"])],
    dependencies: [.package(path: "../../NagiKit")],
    targets: [.target(name: "DebugEffects", dependencies: ["NagiKit"])]
)
