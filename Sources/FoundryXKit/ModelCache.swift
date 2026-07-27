import Foundation

// A tiny warm cache for the chat model picker (track 20260715T1501). Opening the model
// dropdown fetches `GET /foundryx/models` over the door tunnel (~3s); until it returns the
// menu can only render the hardcoded "Auto" pick. This persists the last-known list to
// UserDefaults so the picker paints the full grouped menu instantly on open, while a
// background refresh silently replaces the cache when the live list differs.
//
// UserDefaults + JSON is the established phone-side caching pattern (DeviceManager,
// CaptureSourceRegistry, BrainStore). The cache is best-effort: a miss or a decode failure
// yields an empty list (the no-regression "Auto only, then populate" first-launch path).
public enum ModelCache {

    /// The persisted key. Versioned so a wire-shape change can invalidate cleanly.
    static let key = "foundryx.models.cache.v1"

    /// The last-known model list, or `[]` on a cold cache / decode failure.
    public static func load() -> [ModelOption] {
        guard case .value(let data) = AccountPreferences.read(
            AccountPreferenceCatalog.modelsCache),
              let models = try? JSONDecoder().decode([ModelOption].self, from: data)
        else { return [] }
        return models
    }

    public static func load(_ defaults: UserDefaults) -> [ModelOption] {
        load(
            compatibility: .init(defaults: defaults),
            generation: 0)
    }

    public static func load(
        compatibility: AccountPreferenceCompatibilityStore,
        generation: UInt64
    ) -> [ModelOption] {
        _ = generation
        guard case .value(let data) = compatibility.read(
            AccountPreferenceCatalog.modelsCache),
              let models = try? JSONDecoder().decode([ModelOption].self, from: data)
        else { return [] }
        return models
    }

    /// Persist a freshly-fetched list. A no-op on encode failure (the live `models` state is
    /// still refreshed in memory regardless).
    @discardableResult
    public static func save(
        _ models: [ModelOption],
        generation: UInt64? = nil
    ) -> AccountPreferenceWriteResult {
        guard let data = try? JSONEncoder().encode(models) else {
            return .unresolved
        }
        return AccountPreferences.write(
            data,
            for: AccountPreferenceCatalog.modelsCache,
            generation: generation)
    }

    public static func save(_ models: [ModelOption], _ defaults: UserDefaults) {
        _ = save(
            models,
            compatibility: .init(defaults: defaults),
            generation: 0)
    }

    @discardableResult
    public static func save(
        _ models: [ModelOption],
        compatibility: AccountPreferenceCompatibilityStore,
        generation: UInt64
    ) -> AccountPreferenceWriteResult {
        _ = generation
        guard let data = try? JSONEncoder().encode(models) else {
            return .unresolved
        }
        return compatibility.write(
            data,
            for: AccountPreferenceCatalog.modelsCache)
    }
}
