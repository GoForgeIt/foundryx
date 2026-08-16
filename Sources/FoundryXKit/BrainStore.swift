// BrainStore — which brain this phone uses (onboarding track 20260705T1100).
// "Just my phone" (free, zero content egress) · "My computer" (desktop Foundry via
// the door — today's flow) · "Foundry Cloud" (waitlist until the cell ships).
// Switching is additive, never destructive (spec §4): choosing a brain never
// deletes local data; connecting a computer replay-seeds it (Phase 7).

import Foundation

public enum BrainChoice: String, CaseIterable, Sendable {
    case justMyPhone = "phone"
    case myComputer = "computer"
    /// Rung 3 (track 20260705T1100 §5): a hosted Foundry CELL as the brain. Same
    /// FoundryX door surface (`/foundryx/*`) as "my computer", but reached over a
    /// direct public HTTPS URL (the cell has a public address — no relay), grant =
    /// the user's sign-in id_token OR a pasted door bearer (see CellBackend).
    case foundryCloud = "cloud"

    public var label: String {
        switch self {
        case .justMyPhone: return "Just my phone"
        case .myComputer: return "My computer"
        case .foundryCloud: return "Solleva Cloud"
        }
    }

    /// DOES A SEGMENT UPLOAD-ACK MEAN THE BYTES REACHED SOMEWHERE THAT IS NOT THIS PHONE?
    ///
    /// For `.justMyPhone` it does NOT, and the app's own code says so: `CaptureManager`'s
    /// brain-seam initialiser passes `uploadSegment: localMode ? { @Sendable _, _, _ in } : nil`
    /// — a closure that succeeds by doing nothing — and documents that on this tier the WAL's
    /// ack means *"durably on this phone"*. Reading `CaptureStage.savedToComputer` as proof of
    /// another place is therefore false exactly where it is most expensive: the phone-only tier
    /// is the one where the phone holds the only copy.
    ///
    /// It lives on the choice rather than at the call site because the call sites are the
    /// safety predicate and, next, the delete. One of them forgetting is a lost recording.
    public var uploadAckProvesAnotherPlace: Bool {
        switch self {
        case .justMyPhone:              return false
        case .myComputer, .foundryCloud: return true
        }
    }
}

/// Durable brain selection. MIGRATION-SAFE default: an install that has already
/// paired with a desktop (a resolved host) stays on `.myComputer`; a fresh install
/// defaults to `.justMyPhone` (spec §3 — the free tier is the default).
public final class BrainStore: ObservableObject, @unchecked Sendable {
    private static let key = "foundryx.brain.choice"
    private let compatibility: AccountPreferenceCompatibilityStore?

    @Published public private(set) var choice: BrainChoice
    /// True once the user (or the pairing migration) explicitly picked a brain —
    /// lets RootView adopt `.myComputer` for pre-picker installs exactly once.
    public var hasExplicitChoice: Bool {
        if let compatibility {
            return compatibility.hasLegacyStringValue(
                for: AccountPreferenceCatalog.brainChoice)
        }
        if case .value = AccountPreferences.read(
            AccountPreferenceCatalog.brainChoice) {
            return true
        }
        return false
    }

    public init(hasPairedDesktop: Bool = false) {
        compatibility = nil
        choice = Self.readActiveChoice(
            hasPairedDesktop: hasPairedDesktop)
    }

    public init(defaults: UserDefaults, hasPairedDesktop: Bool = false) {
        compatibility = .init(defaults: defaults)
        choice = Self.readChoice(
            compatibility: compatibility!,
            hasPairedDesktop: hasPairedDesktop)
    }

    public init(
        compatibility: AccountPreferenceCompatibilityStore,
        hasPairedDesktop: Bool = false
    ) {
        self.compatibility = compatibility
        choice = Self.readChoice(
            compatibility: compatibility,
            hasPairedDesktop: hasPairedDesktop)
    }

    public func select(_ c: BrainChoice) {
        choice = c
        if let compatibility {
            _ = compatibility.write(
                c.rawValue,
                for: AccountPreferenceCatalog.brainChoice)
        } else {
            _ = AccountPreferences.write(
                c.rawValue,
                for: AccountPreferenceCatalog.brainChoice)
        }
    }

    public func refresh(
        generation: UInt64,
        hasPairedDesktop: Bool = false
    ) {
        guard generation == CaptureAccountScope.identityGeneration else {
            return
        }
        if let compatibility {
            choice = Self.readChoice(
                compatibility: compatibility,
                hasPairedDesktop: hasPairedDesktop)
        } else {
            choice = Self.readActiveChoice(
                hasPairedDesktop: hasPairedDesktop)
        }
    }

    private static func readChoice(
        compatibility: AccountPreferenceCompatibilityStore,
        hasPairedDesktop: Bool
    ) -> BrainChoice {
        let context = AccountPreferenceCompatibilityContext(
            hasPairedDesktop: hasPairedDesktop)
        guard case .value(let raw) = compatibility.read(
            AccountPreferenceCatalog.brainChoice,
            context: context),
              let choice = BrainChoice(rawValue: raw) else {
            return hasPairedDesktop ? .myComputer : .justMyPhone
        }
        return choice
    }

    private static func readActiveChoice(
        hasPairedDesktop: Bool
    ) -> BrainChoice {
        guard case .value(let raw) = AccountPreferences.read(
            AccountPreferenceCatalog.brainChoice),
              let choice = BrainChoice(rawValue: raw) else {
            return hasPairedDesktop ? .myComputer : .justMyPhone
        }
        return choice
    }
}
