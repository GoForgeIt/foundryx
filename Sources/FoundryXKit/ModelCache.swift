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
    public static func load(_ defaults: UserDefaults = .standard) -> [ModelOption] {
        guard let data = defaults.data(forKey: key),
              let models = try? JSONDecoder().decode([ModelOption].self, from: data)
        else { return [] }
        return models
    }

    /// Persist a freshly-fetched list. A no-op on encode failure (the live `models` state is
    /// still refreshed in memory regardless).
    public static func save(_ models: [ModelOption], _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        defaults.set(data, forKey: key)
    }
}
