// swift-tools-version: 6.2
// M0 spike apps (docs/M0-PLAN.md section 2). Throwaway code.
// Built by Spikes/scripts/build-spikes.sh, which assembles and signs the .app bundles.
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../PackageProbe")],
    targets: [
        // JSON Lines on stdout, shared by both apps so their logs can be correlated.
        .target(name: "SpikeLog"),
        .executableTarget(
            name: "Harness",
            dependencies: ["SpikeLog", .product(name: "ProbeShaders", package: "PackageProbe")],
            resources: [.process("Overlay.metal")]
        ),
        .executableTarget(name: "Fixture", dependencies: ["SpikeLog"]),
    ]
)
