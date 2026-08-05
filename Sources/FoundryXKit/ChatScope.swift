import Foundation

/// WHICH CHATS AM I LOOKING AT — the two bodies of work the chat surface can show, and the
/// words that tell them apart.
///
/// WHY THIS TYPE EXISTS.
/// --------------------
/// The chat header used to carry two sibling text buttons: **"Chats"** (this phone's own
/// list) and **"All"** (Kiln's shared library on the Mac — its own chats plus every imported
/// Claude Code / Codex transcript). Two short, quantifier-shaped labels sitting side by side
/// read as a FILTER PAIR over one list, not as doors onto two different corpora. It was worse
/// than ambiguous: the sheet behind "Chats" has its own `All` provenance chip, so the word
/// "All" appeared twice on one screen meaning two unrelated things.
///
/// The observed failure (build 387): the owner opened the obvious one, saw the handful of
/// chats this phone had started, and reported that the desktop library had not shipped. It
/// had. He had simply opened the other door.
///
/// So the choice is modelled HERE rather than spelled inline in the view, for three reasons:
///
///   1. The header renders `allCases`. Adding a corpus without giving it a name and a
///      caption becomes impossible — you cannot add a case without answering both.
///   2. A quantifier is not a name. `isBareQuantifier` is the rule the Brine suite holds the
///      copy to, so "All" (or "Everything", or "Other") cannot come back as a label.
///   3. Every caption must say what is actually behind the choice — for the Mac, that means
///      naming Kiln, Claude Code and Codex, which is the whole reason someone reaches for it.
public enum ChatScope: String, CaseIterable, Sendable, Equatable {

    /// Chats this phone started and holds locally (`ChatConversationStore`).
    case thisPhone

    /// Everything Kiln holds on the Mac: its own chats, and every Claude Code / Codex
    /// transcript it has imported. This is the corpus that can be picked back up.
    case onYourMac

    /// The choice as it reads in the menu. Names a PLACE, never a quantity.
    public var title: String {
        switch self {
        case .thisPhone: return "On this phone"
        case .onYourMac: return "On your Mac"
        }
    }

    /// What is actually behind the choice, shown at the point of choice — before committing
    /// to it, not after opening the wrong one.
    public var caption: String {
        switch self {
        case .thisPhone:
            return "Chats you started here"
        case .onYourMac:
            return "Kiln, Claude Code and Codex — pick any of them back up"
        }
    }

    /// SF Symbol for the menu row. A phone and a desktop read as two places at a glance.
    public var symbol: String {
        switch self {
        case .thisPhone: return "iphone"
        case .onYourMac: return "desktopcomputer"
        }
    }

    /// Kept from the two-button era on purpose: these identifiers are existing test
    /// contracts, and renaming them would have made a copy fix look like a behaviour change.
    public var accessibilityIdentifier: String {
        switch self {
        case .thisPhone: return "open-chats"
        case .onYourMac: return "open-kiln-library"
        }
    }

    /// Words that COUNT rather than NAME. A control labelled with one of these tells the
    /// reader nothing about what it opens, and beside a sibling it reads as a filter.
    public static let bareQuantifiers = ["all", "everything", "other", "more", "rest"]

    /// Is `label` a bare quantifier — the exact defect this type replaced?
    public static func isBareQuantifier(_ label: String) -> Bool {
        let trimmed = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return bareQuantifiers.contains(trimmed)
    }
}

/// The single header control that reveals the two scopes.
public enum ChatScopeCopy {

    /// The one control on the chat header. ONE control, not two siblings: there is no longer
    /// a wrong door to guess at.
    public static let controlLabel = "Chats"
    public static let controlAccessibilityIdentifier = "chat-scope-picker"
    public static let controlAccessibilityLabel = "Which chats"
    public static let controlAccessibilityHint =
        "Chooses between the chats on this phone and the chats on your Mac"
}
