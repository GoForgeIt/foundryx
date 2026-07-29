import SwiftUI

/// Defers building a destination view until SwiftUI actually renders it. `NavigationLink`'s
/// `destination:` is an autoclosure-free @ViewBuilder evaluated WITH the link, so an
/// expensive destination is constructed on every body pass of the screen carrying the link
/// (track `residual_on_main_actor_work`). Wrapping it moves that construction to first
/// render of the destination itself.
///
/// WHY IT LIVES IN THE KIT RATHER THAN IN `App/RootView.swift` (review round 13, M13-2).
/// Two call sites depend on this type being LAZY — the conversation row's detail push (which
/// otherwise reads each capture's device record off disk, on the main actor, once per row per
/// body pass) and the Stats destination. The only gate holding either was a source-text search
/// for the string `LazyView { conversationDetail(wal) }`, and a gate that measures a NAME is
/// satisfied by anything wearing it: an eager impostor with the same name and the same call
/// sites —
///
/// ```swift
/// struct LazyView<Content: View>: View {
///     private let built: Content
///     init(@ViewBuilder _ build: @escaping () -> Content) { self.built = build() }
///     var body: some View { built }
/// }
/// ```
///
/// — restored the whole pathology with every gate green (MUT-R13-P5, SURVIVED). `swift test`
/// compiles the SPM package only; it cannot see `App/`, so no test could even NAME the type
/// while it was declared there. Here it can: `LazyViewDefersItsContentTests` constructs one
/// with a closure that counts its own invocations and asserts the count is ZERO until `body`
/// is asked for. The App target compiles `Sources/FoundryXKit` directly into its own module,
/// so this is the same type at the same call sites — and a second `LazyView` declared under
/// `App/` would now be a redeclaration the compile gate rejects.
struct LazyView<Content: View>: View {
    private let build: () -> Content
    init(@ViewBuilder _ build: @escaping () -> Content) { self.build = build }
    var body: some View { build() }
}
