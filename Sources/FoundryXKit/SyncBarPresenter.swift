// SyncBarPresenter — the pure hysteresis model behind the capture screen's one-line
// sync strip (UX-polish WS-B).
//
// The raw "is a determinate segment drain active?" signal flaps: a brief backfill
// blinks true for a fraction of a second, or a drain finishes the instant it started.
// If the UI reacted to that signal directly, the blue progress row would pop in and
// out jerkily. This model sits between the raw signal and the view and enforces two
// human-friendly guarantees:
//
//   • APPEAR DELAY — syncing must stay continuously active for longer than
//     `appearDelay` (1.5s) before the syncing presentation is shown at all. Brief
//     drains never surface it.
//   • MINIMUM SHOW  — once shown, the syncing presentation persists for at least
//     `minShow` (3s), even if the drain finishes sooner, before it settles back. No
//     flicker: the row can never blink out in under three seconds once it appears.
//
// The model is pure and clock-injectable: the caller passes the current time to every
// `step`, so the view drives it from a TimelineView tick (no Timer to leak) and unit
// tests drive it with a synthetic clock. It carries no view or timing machinery of its
// own — the SwiftUI layer is a thin binding.

import Foundation

// MARK: - Presentation

/// What the sync strip should present. The row is ALWAYS a fixed-height single line
/// whenever there are captures; only which of these two contents it shows changes
/// (and it cross-fades between them in the view).
public enum SyncBarPresentation: Equatable, Sendable {
    /// The determinate drain is on screen — status text plus the thin inline bar.
    case syncing
    /// No syncing presentation — the caller renders its settled content instead
    /// (pending detail, or the calm "all saved" line). Never shows the progress bar.
    case settled
}

// MARK: - Presenter

public struct SyncBarPresenter: Equatable, Sendable {

    /// The two hysteresis thresholds. Defaults encode the WS-B contract (1.5s / 3s).
    public struct Config: Equatable, Sendable {
        /// Syncing must be continuously active for STRICTLY LONGER than this before the
        /// syncing presentation appears (a brief drain never shows it).
        public var appearDelay: TimeInterval
        /// Once shown, the syncing presentation persists for at least this long before
        /// settling — even if the drain finishes sooner.
        public var minShow: TimeInterval

        public init(appearDelay: TimeInterval = 1.5, minShow: TimeInterval = 3.0) {
            self.appearDelay = appearDelay
            self.minShow = minShow
        }

        public static let `default` = Config()
        /// For proof/screenshot harnesses: show the syncing presentation immediately and
        /// let it settle immediately, so a single-frame capture renders the real strip.
        public static let immediate = Config(appearDelay: 0, minShow: 0)
    }

    public let config: Config

    /// The internal hysteresis phase — the whole of the model's memory.
    private enum Phase: Equatable {
        /// Not presenting; syncing is (as far as we've sampled) inactive.
        case settled
        /// Syncing turned active at `since`; waiting out the appear delay. Not yet shown.
        case pending(since: Date)
        /// The syncing presentation is on screen; it first became visible at `shownAt`.
        case showing(shownAt: Date)
    }
    private var phase: Phase = .settled

    public init(config: Config = .default) {
        self.config = config
    }

    /// The current presentation without advancing the clock.
    public var presentation: SyncBarPresentation {
        if case .showing = phase { return .syncing }
        return .settled
    }

    /// Advance the machine with the current raw `syncing` signal sampled at `now`.
    /// Returns the presentation to render. Idempotent for a fixed `(syncing, now)`.
    @discardableResult
    public mutating func step(syncing: Bool, now: Date) -> SyncBarPresentation {
        switch phase {
        case .settled:
            if syncing {
                // Start the appear-delay clock; nothing shows yet.
                phase = .pending(since: now)
            }

        case .pending(let since):
            if syncing {
                // Continuously active — reveal only once we're STRICTLY past the delay.
                if now.timeIntervalSince(since) > config.appearDelay {
                    phase = .showing(shownAt: now)
                }
            } else {
                // The drain stopped before the delay elapsed — it never earns the row.
                phase = .settled
            }

        case .showing(let shownAt):
            if syncing {
                // Keep showing; the original `shownAt` anchors the minimum-show window.
                break
            }
            // Drain finished: hold the row until the minimum-show window has elapsed.
            if now.timeIntervalSince(shownAt) >= config.minShow {
                phase = .settled
            }
        }
        return presentation
    }
}

// MARK: - Strip layout (single source of truth for the no-layout-shift guarantee)

/// The strip's geometry, shared by the SwiftUI view AND the tests. The whole point of
/// WS-B is that the strip is ONE height for every presentation, so content below it can
/// never move — `height(for:)` returns the same constant for every case by construction.
public enum SyncStripLayout {
    /// The constant inner row height (caption line + breathing room; the 6-pt inline bar
    /// is shorter, so its presence never changes the height).
    public static let rowHeight: Double = 22
    /// Vertical padding around the row (Grain x2 top / x1 bottom).
    public static let topPadding: Double = 8
    public static let bottomPadding: Double = 4
    /// The strip's fixed outer height — the value the layout reserves in EVERY state.
    public static var totalHeight: Double { rowHeight + topPadding + bottomPadding }

    /// The height for a given presentation — CONSTANT across presentations, which IS the
    /// zero-layout-shift guarantee, made assertable.
    public static func height(for presentation: SyncBarPresentation) -> Double { totalHeight }
}

// MARK: - Strip copy (single source of truth for the settled "all saved" line)

/// The calm settled copy for the strip, shared by the view and the tests so the "all
/// saved" wording is verified against the real string, never a duplicate.
public enum SyncStripCopy {
    /// The all-saved line. `local` (phone-only tier) has no "computer" to copy to.
    public static func allSaved(local: Bool) -> String {
        local ? "All voice notes saved" : "All voice notes saved to computer"
    }
}
