// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FoundryX",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "FoundryXKit", targets: ["FoundryXKit"]),
    ],
    dependencies: [
        // The reusable Swift Brine runner (M1) — test-only dependency.
        .package(name: "brine-swift", path: "../brine-private/runners/implementations/swift"),
    ],
    targets: [
        .target(name: "FoundryXKit"),
        .testTarget(
            name: "FoundryXBrineTests",
            dependencies: [
                "FoundryXKit",
                .product(name: "BrineSwiftCore", package: "brine-swift"),
            ]
        ),
    ]
)
