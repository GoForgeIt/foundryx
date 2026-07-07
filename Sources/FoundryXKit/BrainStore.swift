// BrainStore — which brain this phone uses (onboarding track 20260705T1100).
// "Just my phone" (free, zero content egress) · "My computer" (desktop Foundry via
// the door — today's flow) · "Foundry Cloud" (waitlist until the cell ships).
// Switching is additive, never destructive (spec §4): choosing a brain never
// deletes local data; connecting a computer replay-seeds it (Phase 7).

import Foundation

public enum BrainChoice: String, CaseIterable, Sendable {
    case justMyPhone = "phone"
    case myComputer = "computer"

    public var label: String {
        switch self {
        case .justMyPhone: return "Just my phone"
        case .myComputer: return "My computer"
        }
    }
}

/// Durable brain selection. MIGRATION-SAFE default: an install that has already
/// paired with a desktop (a resolved host) stays on `.myComputer`; a fresh install
/// defaults to `.justMyPhone` (spec §3 — the free tier is the default).
public final class BrainStore: ObservableObject, @unchecked Sendable {
    private static let key = "foundryx.brain.choice"
    private let defaults: UserDefaults

    @Published public private(set) var choice: BrainChoice

    public init(defaults: UserDefaults = .standard, hasPairedDesktop: Bool = false) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.key), let saved = BrainChoice(rawValue: raw) {
            choice = saved
        } else {
            choice = hasPairedDesktop ? .myComputer : .justMyPhone
        }
    }

    public func select(_ c: BrainChoice) {
        choice = c
        defaults.set(c.rawValue, forKey: Self.key)
    }
}
