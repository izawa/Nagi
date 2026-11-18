// swift-tools-version: 6.4
// NagiKit: the effect API (protocols and value types only). SPEC 3.2, 3.4.
import PackageDescription

let package = Package(
    name: "NagiKit",
    platforms: [.macOS(.v27)],
    products: [.library(name: "NagiKit", targets: ["NagiKit"])],
    targets: [
        .target(name: "NagiKit"),
        .testTarget(name: "NagiKitTests", dependencies: ["NagiKit"]),
    ]
)
