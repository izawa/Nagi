// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PackageProbe",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ProbeShaders", type: .static, targets: ["ProbeShaders"]),
        .executable(name: "probe", targets: ["probe"]),
    ],
    targets: [
        .target(
            name: "ProbeShaders",
            // Let the build system process Metal source into the bundle's default.metallib.
            resources: [.process("Shaders.metal")]
        ),
        .executableTarget(name: "probe", dependencies: ["ProbeShaders"]),
    ]
)
