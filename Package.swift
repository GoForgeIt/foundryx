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
        // BLAKE2s-256 (pure Swift, iOS16+) — the hash for the Noise_XX relay channel.
        .package(url: "https://github.com/trancee/blake-hash.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "FoundryXKit",
            dependencies: [
                .product(name: "Grain", package: "Grain"),
                .product(name: "BlakeHash", package: "blake-hash"),
            ]
        ),
        .testTarget(
            name: "FoundryXBrineTests",
            dependencies: [
                "FoundryXKit",
                .product(name: "BrineSwiftCore", package: "brine-swift"),
            ],
            // The T0 verifier of track 20260725T2306 reads these by REPO PATH (the same
            // `#filePath`-relative mechanism BrineFeatureRunner uses for features/), not
            // through Bundle.module, so they are excluded rather than copied.
            exclude: [
                "then-capabilities.json",
                "fixtures/device-agnostic",
            ],
            resources: [
                .copy("fixtures/handshake_vectors.json"),
                .copy("fixtures/omi_real_frames.json"),
            ]
        ),
    ]
)
