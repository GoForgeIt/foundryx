import XCTest
import SwiftUI
@testable import FoundryXKit
import Grain

/// POCKET-P7 — "when I tap use recorder WiFi, nothing happens."
///
/// The button was not broken. It was `.disabled(…)`: `PocketFastSyncEndpoint.measured`
/// is nil because nobody has ever confirmed the address a Pocket serves files from
/// (`PROTOCOL.md:149` still reads "HTTP endpoint: TBD"), so
/// `PocketRecorderCheckModel.fastSyncCanRun` is false and the button cannot run. The
/// sentence underneath it says exactly that.
///
/// THE DEFECT THIS FILE GUARDS IS NOT THE UNWIRED ENDPOINT. It is that a disabled
/// `.grain` button rendered pixel-for-pixel identically to a live one — same fill, same
/// border, same ink, same shadow, full opacity — so "disabled" and "broken" were the
/// same experience. `GrainButtonStyle` never read `\.isEnabled` at all, and a
/// `ButtonStyle` gets no free treatment from SwiftUI the way `.borderedProminent` does.
///
/// WHY THIS IS ASSERTED AS A VALUE AND NOT AS PIXELS. `swift test` cannot compile
/// `App/`, and every `GrainColor` is a dynamic color backed by a trait-resolving
/// closure, so two `Color`s neither compare equal when identical nor unequal when
/// different. So the style's whole rendering decision was lifted into
/// `GrainButtonStyle.appearance(variant:size:pressed:isEnabled:)`, a pure function
/// returning named tokens — the same pattern this codebase already uses to keep
/// decisions out of SwiftUI bodies where nothing can hold them.
final class GrainDisabledButtonLegibilityTests: XCTestCase {

    /// EVERY variant, at EVERY size, must render differently when it cannot respond.
    ///
    /// The blast radius of this rule is every Grain button in the app — 10
    /// `.buttonStyle(.grain(…))` sites and 70 `GrainButton(…)` sites at the time it was
    /// written — which is the point: the fix belongs to the style, not to the one call
    /// site that got complained about.
    func testDisabledRendersDifferentlyFromEnabledForEveryVariantAndSize() {
        for variant in GrainButtonVariant.allCases {
            for size in GrainButtonSize.allCases {
                let live = GrainButtonStyle.appearance(variant: variant, size: size, pressed: false, isEnabled: true)
                let dead = GrainButtonStyle.appearance(variant: variant, size: size, pressed: false, isEnabled: false)
                XCTAssertNotEqual(
                    live, dead,
                    "a disabled .grain(\(variant)) at size \(size) renders identically to a live one — "
                    + "'disabled' and 'broken' are the same experience"
                )
            }
        }
    }

    /// One channel is not enough. A difference carried only by whole-control opacity
    /// disappears under Reduce Transparency and under a photograph of the screen at an
    /// angle; a difference carried only by ink disappears for a button whose label is an
    /// icon on a fill. So the ink AND the surface must both move.
    func testDisabledDiffersInInkAndInSurfaceNotOpacityAlone() {
        for variant in GrainButtonVariant.allCases {
            let live = GrainButtonStyle.appearance(variant: variant, isEnabled: true)
            let dead = GrainButtonStyle.appearance(variant: variant, isEnabled: false)

            XCTAssertNotEqual(live.foreground, dead.foreground,
                              "disabled .grain(\(variant)) keeps the live ink token \(live.foreground.rawValue)")

            let surfaceMoved = live.background != dead.background
                || live.border != dead.border
                || live.borderWidth != dead.borderWidth
            XCTAssertTrue(surfaceMoved,
                          "disabled .grain(\(variant)) keeps the live surface: fill \(live.background.rawValue), "
                          + "border \(live.border.rawValue) @\(live.borderWidth)")

            XCTAssertLessThan(dead.opacity, live.opacity,
                              "disabled .grain(\(variant)) is drawn at full strength")
        }
    }

    /// A control that cannot respond must not pretend to be liftable either: no
    /// elevation, and no depress-while-held.
    func testDisabledIsFlatAndDoesNotDepress() {
        for variant in GrainButtonVariant.allCases {
            let dead = GrainButtonStyle.appearance(variant: variant, pressed: true, isEnabled: false)
            XCTAssertEqual(dead.elevation, .e0,
                           "disabled .grain(\(variant)) still casts a shadow, which reads as liftable")
            XCTAssertEqual(dead.pressScale, 1, accuracy: 0.0001,
                           "disabled .grain(\(variant)) still depresses under a finger")
        }
    }

    /// THE REAL PRODUCTION PAIRINGS, RE-POINTED 2026-08-21.
    ///
    /// This case originally pinned the fast-sync button — `.grain(.outlined)` gated by
    /// `.disabled(… || !fastSyncCanRun)`, which was false on every phone because
    /// `PocketFastSyncEndpoint.measured` had never been confirmed. That is the control Nick
    /// tapped when nothing happened, and it is the reason this whole file exists.
    ///
    /// **That button no longer exists.** P0 withdrew fast sync outright once the recorder's
    /// access point was measured dropping clients ~8s after the handshake, so
    /// `PocketFastSyncEndpoint` is gone from the codebase. Re-pointing rather than deleting:
    /// the ORIGINAL subject is gone, but the guarantee it was pinning — that a specific
    /// production pairing cannot be quietly re-flattened by a refactor of the variant table —
    /// applies to every `.disabled` + `.grain` pairing still shipping.
    ///
    /// These are the variants actually paired with `.disabled(…)` in `App/DeviceScreen.swift`
    /// today (`:1333`, `:1378`, `:1774`). The general rule is held by the tests above; this
    /// one exists so the specific controls a person can actually reach are named.
    func testEveryVariantActuallyDisabledInProductionLooksUnavailable() {
        // Taken from the real call sites, not from the full variant list — a guard over
        // `allCases` would stay green if production moved to a variant nobody checked.
        let pairedWithDisabledInProduction: [GrainButtonVariant] =
            [.outlined, .destructive, .filled, .text]

        for variant in pairedWithDisabledInProduction {
            let live = GrainButtonStyle.appearance(variant: variant)
            let dead = GrainButtonStyle.appearance(variant: variant, isEnabled: false)
            XCTAssertNotEqual(
                live, dead,
                ".grain(\(variant)) is paired with .disabled(…) in DeviceScreen and still looks "
                + "exactly like a button that can be pressed")
        }
    }

    /// The guard must not be satisfiable by making the DISABLED renderings differ from
    /// each other while still colliding with some live variant. No disabled appearance
    /// may equal any live appearance, of any variant.
    func testNoDisabledAppearanceCollidesWithAnyLiveVariant() {
        let live = GrainButtonVariant.allCases.flatMap { v in
            [GrainButtonStyle.appearance(variant: v, pressed: false),
             GrainButtonStyle.appearance(variant: v, pressed: true)]
        }
        for variant in GrainButtonVariant.allCases {
            let dead = GrainButtonStyle.appearance(variant: variant, isEnabled: false)
            XCTAssertFalse(live.contains(dead),
                           "the disabled rendering of .grain(\(variant)) is indistinguishable from some live button")
        }
    }
}
