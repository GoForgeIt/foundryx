// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FoundryX",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "FoundryXKit", targets: ["FoundryXKit"]),
    ],
    dependencies: [
        // Grain — the shared SwiftUI design system (tokens + components).
        .package(name: "Grain", path: "../grain/platforms/grain-swift"),
        // The reusable Swift Brine runner (M1) — test-only dependency.
        .package(name: "brine-swift", path: "../brine-private/runners/implementations/swift"),
    ],
    targets: [
        .target(
            name: "FoundryXKit",
            dependencies: [.product(name: "Grain", package: "Grain")]
        ),
        .testTarget(
            name: "FoundryXBrineTests",
            dependencies: [
                "FoundryXKit",
                .product(name: "BrineSwiftCore", package: "brine-swift"),
            ]
        ),
    ]
)
