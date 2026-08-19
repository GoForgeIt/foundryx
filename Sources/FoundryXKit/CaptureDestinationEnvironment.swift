// CaptureDestinationEnvironment — THE TIER, RESOLVED ONCE, READ EVERYWHERE.
//
// WHY THIS EXISTS (X3, cross-vendor review 2026-08-19).
// -----------------------------------------------------
// The tier was correct in the kit and THREADED BY HAND through the view tree: MainTabs
// → CaptureScreen → ConversationFacesView → `WaitingExperienceModel(kind:destination:)`.
// Every hop is a place to pass the wrong value, and `swift test` cannot compile `App/`,
// so NOTHING could see it go wrong. `3e8e1db` is the existence proof: only the compiler
// caught a MISSING `destination`, and only because the type forced it — nothing forces
// the VALUE. Changing one argument at `ConversationFacesView` from `destination` to
// `.computer` restored the false wait and left every suite green.
//
// So the value is written ONCE, at the root, from `RootDestination.captureDestinationOnScreen`
// — the mapping `RootDestinationDestinationTests` executes — and read from the
// environment by the surfaces that render tier-specific copy. There is one assignment
// in the whole app, and it is derived, not typed.
//
// THE DEFAULT IS `.phone`, AND THAT IS A LOAD-BEARING CHOICE, NOT A SHRUG.
// -----------------------------------------------------------------------
// A SwiftUI EnvironmentKey must have a default, and this program's own rule is that a
// default about where a person's audio went is "a decision made by whoever forgot".
// That rule is about defaults that can NAME A PLACE THE OWNER DOES NOT HAVE. The phone
// is the one tier that names no second place at all — it is on every tier (the app runs
// there), so its words are true of every owner's local storage and can never invent a
// Mac or a Vault. A forgotten `.environment` therefore degrades to saying LESS, never to
// saying something false about a machine somebody does not own.
//
// That is not an assertion; it is the property `CaptureDestinationFallbackTests` holds
// over every tier-varying sentence in the program.

import SwiftUI

public enum CaptureDestinationEnvironment {

    /// The value a surface reads when no root has written one.
    ///
    /// It is `.phone` because the phone tier's copy names no place its reader lacks —
    /// see the file header, and the executable claim in `CaptureDestinationFallbackTests`.
    public static let fallback: CaptureDestination = .phone
}

private struct CaptureDestinationKey: EnvironmentKey {
    static let defaultValue: CaptureDestination = CaptureDestinationEnvironment.fallback
}

public extension EnvironmentValues {

    /// WHERE THIS OWNER'S VOICE NOTES LAND. Written once by `RootView`; read by every
    /// surface whose words differ by tier, so no view takes a destination argument it
    /// could be handed wrongly.
    var captureDestination: CaptureDestination {
        get { self[CaptureDestinationKey.self] }
        set { self[CaptureDestinationKey.self] = newValue }
    }
}
