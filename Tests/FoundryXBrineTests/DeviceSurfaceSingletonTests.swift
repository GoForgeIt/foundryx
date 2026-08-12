import XCTest
import Foundation

/// T13 `A8` — EXACTLY ONE DEVICE SURFACE.
///
/// THE CRITERION: *"A structural claim about the app that a rename could quietly break by
/// leaving a second surface behind, and it is **non-vacuous first** in this repo's
/// established house pattern"*, with the mutation leg *"add a second view that owns
/// pairing state -> the scan reports 2 and names both"*.
///
/// WHY THIS FILE EXISTS.  T13's disposition recorded A8 as **subject present, no check**:
///
///     `App/DeviceScreen.swift` and `Sources/FoundryXKit/CellStore.swift` exist, and
///     `AppSourceTree.appSideSwiftFiles()` (the walker A8 names) exists at
///     `Tests/FoundryXBrineTests/AppSourceTree.swift:38`. There is **no
///     exactly-one-device-surface scan and no vacuity leg**. Its row therefore still
///     names no seam, and naming one that does not exist to satisfy
///     `completion-bar.py` C2 was refused.
///
/// That refusal was right, and this is the scan it was refusing to pretend existed.
///
/// WHAT "OWNS PAIRING STATE" MEANS, AND WHY IT IS A DECLARATION AND NOT A MENTION.
/// A device surface is a view that HOLDS the pairing interaction's state — a SwiftUI
/// property wrapper whose stored property is about pairing.  Reading `isPaired`, or
/// passing a `RemoteSession` through, is participation, not ownership; a second view that
/// merely displays paired status is not a second surface and must not redden this.  The
/// scan therefore matches a PROPERTY-WRAPPER DECLARATION, over `AppSourceTree.code(of:)`
/// — comments removed AND string literals blanked — so prose about pairing, and a UI
/// identifier string containing the word, are both excluded.  `swift test` compiles the
/// SPM package only and cannot see `App/`, which is exactly why the walker exists.
final class DeviceSurfaceSingletonTests: XCTestCase {

    /// `@State`/`@StateObject`/`@ObservedObject` … `var <something>Pairing<something>`.
    private static let ownsPairingState = try! NSRegularExpression(
        pattern: "@(State|StateObject|ObservedObject)[^\\n=]*\\b[A-Za-z]*[Pp]airing[A-Za-z]*\\b")

    private func surfacesOwningPairingState() throws -> (surfaces: [String], examined: Int) {
        var hits: [String] = []
        var examined = 0
        for file in try AppSourceTree.appSideSwiftFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            examined += 1
            let code = AppSourceTree.code(of: text)
            let range = NSRange(location: 0, length: (code as NSString).length)
            if Self.ownsPairingState.firstMatch(in: code, range: range) != nil {
                hits.append(AppSourceTree.relativePath(file))
            }
        }
        return (hits.sorted(), examined)
    }

    /// NON-VACUOUS FIRST, which the criterion asks for by name.  A walk that found no
    /// files would make every count below trivially whatever it wanted, and "exactly one"
    /// over an empty tree is the unfailable check this program refuses.
    func testTheScanActuallyWalksTheAppSideTree() throws {
        let (_, examined) = try surfacesOwningPairingState()
        XCTAssertGreaterThan(examined, 0,
                             "the app-side walk read ZERO files; every count this suite "
                             + "reports would be a number about an empty set")
    }

    func testExactlyOneDeviceSurfaceOwnsPairingState() throws {
        let (surfaces, examined) = try surfacesOwningPairingState()
        XCTAssertEqual(
            surfaces.count, 1,
            "expected EXACTLY ONE app-side view owning pairing state; found "
            + "\(surfaces.count) across \(examined) app-side files: "
            + "\(surfaces.isEmpty ? "none" : surfaces.joined(separator: ", "))"
            + ". A second surface is how a rename leaves the old screen behind: both "
            + "compile, both look right, and one of them writes state nothing reads.")
    }

    /// The surface is NAMED, not merely counted.  Without this, moving the pairing state
    /// into some other view would keep the count at one and the criterion would not
    /// notice that the device surface had become a different screen.
    func testTheOneSurfaceIsTheDeviceScreen() throws {
        let (surfaces, _) = try surfacesOwningPairingState()
        XCTAssertEqual(surfaces, ["App/DeviceScreen.swift"],
                       "the single pairing-owning surface is not DeviceScreen; the device "
                       + "surface moved and the count alone did not see it")
    }
}
