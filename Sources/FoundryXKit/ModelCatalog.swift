import Foundation

// Pure, UIKit-free classification + labeling for the chat model picker. The door owns the
// model list (`GET /foundryx/models`); this helper turns that flat `[ModelOption]` into a
// grouped, friendly-labeled menu without hardcoding any specific model id. Keeping it pure
// makes the grouping/labeling Brine- and unit-testable without rendering SwiftUI.

/// The provider bucket a model is grouped under. `local` is the catch-all ("on-device /
/// everything else"), so an unknown id never falls out of the menu.
public enum ModelProvider: String, Sendable, CaseIterable {
    case anthropic
    case openai
    case local

    /// Friendly section header.
    public var title: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        case .local:     return "Local"
        }
    }

    /// Fixed display order: cloud tiers first (Anthropic, OpenAI), then on-device.
    public static let order: [ModelProvider] = [.anthropic, .openai, .local]
}

/// The secure, recommended "Auto (router)" default. The router policy-routes and keeps
/// `pi:local` on-device, only reaching cloud when allowed — so it is the privacy-preserving
/// pick, surfaced with a shield badge + caption and selected by default.
public struct AutoEntry: Sendable, Equatable {
    public let title: String
    public let caption: String
    public let secure: Bool
    public let recommended: Bool

    public init(title: String = "Auto (router)",
                caption: String = "Keeps sensitive data local",
                secure: Bool = true,
                recommended: Bool = true) {
        self.title = title
        self.caption = caption
        self.secure = secure
        self.recommended = recommended
    }
}

/// One provider group of selectable models, rendered as a `Section` in the picker.
public struct ModelGroup: Sendable, Equatable, Identifiable {
    public let provider: ModelProvider
    public let options: [ModelOption]

    public var id: String { provider.rawValue }
    public var title: String { provider.title }

    public init(provider: ModelProvider, options: [ModelOption]) {
        self.provider = provider
        self.options = options
    }
}

/// The full picker as data: the secure Auto default plus the provider groups. The SwiftUI
/// view is a dumb renderer over this value.
public struct ModelMenu: Sendable, Equatable {
    public let auto: AutoEntry
    public let groups: [ModelGroup]

    public init(auto: AutoEntry, groups: [ModelGroup]) {
        self.auto = auto
        self.groups = groups
    }
}

public enum ModelCatalog {

    /// Infer the provider for a model from its id + label (case-insensitive). Cloud families
    /// are matched by well-known tokens; anything else falls into `.local` (the door's
    /// historical default targets are local MLX models).
    public static func provider(for option: ModelOption) -> ModelProvider {
        let hay = "\(option.id) \(option.label)".lowercased()

        func contains(_ needles: [String]) -> Bool { needles.contains { hay.contains($0) } }

        if contains(["claude", "anthropic", "opus", "sonnet", "haiku"]) {
            return .anthropic
        }
        if contains(["gpt", "openai"]) || matchesBareReasoningId(hay) {
            return .openai
        }
        return .local
    }

    /// A friendly, human-readable name for a model. Prefers a meaningful door-supplied label
    /// (non-empty, different from the id); otherwise prettifies the id.
    public static func displayName(for option: ModelOption) -> String {
        let label = option.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty && label.lowercased() != option.id.lowercased() {
            return label
        }
        return prettify(option.id)
    }

    /// Group + order the door's models into the picker menu. Empty providers are omitted, so an
    /// empty / Auto-only door yields zero groups (and the picker still shows the Auto default).
    public static func menu(from options: [ModelOption]) -> ModelMenu {
        var buckets: [ModelProvider: [ModelOption]] = [:]
        for option in options {
            buckets[provider(for: option), default: []].append(option)
        }
        let groups = ModelProvider.order.compactMap { provider -> ModelGroup? in
            guard let opts = buckets[provider], !opts.isEmpty else { return nil }
            return ModelGroup(provider: provider, options: opts)
        }
        return ModelMenu(auto: AutoEntry(), groups: groups)
    }

    // MARK: - internals

    /// Matches a bare OpenAI reasoning id like `o1`, `o3`, `o4` (as a standalone token), but not
    /// substrings inside other words.
    private static func matchesBareReasoningId(_ hay: String) -> Bool {
        for token in hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if token.count <= 4, let first = token.first, first == "o",
               token.dropFirst().allSatisfy({ $0.isNumber }), token.count >= 2 {
                return true
            }
        }
        return false
    }

    /// Turn a raw target id (`local-qwen3-8b`) into a tidy display name (`Qwen3 8b`): strip a
    /// leading provider/local prefix, split on `-`/`_`, capitalize words, upper-case the GPT
    /// acronym, and leave version-ish tokens intact.
    private static func prettify(_ id: String) -> String {
        var stem = id
        for prefix in ["local-", "kiln-", "anthropic-", "openai-"] {
            if stem.lowercased().hasPrefix(prefix) {
                stem = String(stem.dropFirst(prefix.count))
                break
            }
        }
        let words = stem.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        let pretty = words.map { raw -> String in
            let token = String(raw)
            if token.lowercased() == "gpt" { return "GPT" }
            // Mixed alphanumerics (e.g. "qwen3", "4o", "8b", "4.8") keep their shape but get a
            // capitalized first letter when it's alphabetic.
            if let first = token.first, first.isLetter {
                return first.uppercased() + token.dropFirst()
            }
            return token
        }.joined(separator: " ")
        return pretty.isEmpty ? id : pretty
    }
}
