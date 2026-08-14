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
                "fixtures/s05-device-shape-interpretation.json",
                // The Pocket audio fixture is read by REPO PATH too (see its PROVENANCE.txt).
                "fixtures/pocket",
            ],
            resources: [
                .copy("fixtures/handshake_vectors.json"),
                .copy("fixtures/omi_real_frames.json"),
            ]
        ),
        // The NON-HERMETIC conformance target (T25). Separate from FoundryXBrineTests
        // on purpose: that target's runner declares itself hermetic — "no real network,
        // no real hardware; every seam is injected" (BrineFeatureRunner.swift:10) — and a
        // conformance obligation met inside it would be met against our own responder.
        //
        // The separation is a fact of the build graph, not a convention: this target does
        // not depend on FoundryXBrineTests and cannot see `BrineFeatureRunner`, so merging
        // the two stops the build rather than quietly weakening the obligation.
        //
        // It starts a REAL `foundry-relay` process, resolved from the configuration key
        // FOUNDRYX_CONFORMANCE_RELAY_BIN. Absent relay is a RED, never an XCTSkip.
        .testTarget(
            name: "FoundryXConformanceTests",
            dependencies: [
                "FoundryXKit",
                .product(name: "BrineSwiftCore", package: "brine-swift"),
            ],
            // Read by repo path (the same `#filePath`-relative mechanism the feature
            // files use), not through Bundle.module — so it is excluded rather than copied.
            exclude: ["registers/p3-contract-elements.json"]
        ),
    ]
)
