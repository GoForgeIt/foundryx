import Foundation

/// Resolves the bundle that carries this suite's fixture JSON, in BOTH build
/// environments:
///   - `swift test` (SPM): `SWIFT_PACKAGE` is defined → the generated `Bundle.module`.
///   - the Xcode iOS-simulator test target (FoundryXiOSTests): `SWIFT_PACKAGE` is
///     NOT defined and there's no per-target `Bundle.module`, so fall back to the
///     bundle that contains the test class (xcodegen copies the fixtures into it).
/// Using `Bundle.module` unconditionally fails to compile in the Xcode target
/// (it resolves to FoundryXKit's internal accessor — "inaccessible"), so route
/// every fixture lookup through here.
enum TestFixtureBundle {
    static var current: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }
    private final class BundleToken {}
}
