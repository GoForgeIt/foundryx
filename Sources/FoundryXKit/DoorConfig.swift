import Foundation

public struct DoorConfig: Equatable, Sendable {
    public let url: String
    public let bearer: String

    public init?(url: String, bearer: String) {
        guard URL(string: url) != nil, !bearer.isEmpty else { return nil }
        self.url = url
        self.bearer = bearer
    }

    public var doorURL: URL { URL(string: url)! }
}

/// Door URL + bearer persisted in account-scoped preferences and secure storage.
struct DoorConfigStore: @unchecked Sendable {
    static let service = "com.goforgeit.foundryx.door"
    static let urlKey = "foundryx.door.url"

    private let defaults: UserDefaults
    private let keychainService: String
    private let secretStore: any PairingSecretStore

    init(
        defaults: UserDefaults = .standard,
        keychainService: String = DoorConfigStore.service
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.secretStore = SystemPairingSecretStore()
    }

    init(
        defaults: UserDefaults,
        keychainService: String,
        secretStore: any PairingSecretStore
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
        self.secretStore = secretStore
    }

    func load() -> DoorConfig? {
        guard let scoped = CaptureAccountScope.currentScopedPreferences(),
              let url = defaults.string(forKey: scoped.key(Self.urlKey)),
              let bearer = secretStore.read(
                service: keychainService,
                account: scoped.scope) else { return nil }
        return DoorConfig(url: url, bearer: bearer)
    }

    @discardableResult
    func save(_ config: DoorConfig) -> Bool {
        guard let scoped = CaptureAccountScope.currentScopedPreferences(),
              secretStore.replace(
                config.bearer,
                service: keychainService,
                account: scoped.scope) else { return false }
        defaults.set(config.url, forKey: scoped.key(Self.urlKey))
        return true
    }

    static func load() -> DoorConfig? {
        DoorConfigStore().load()
    }

    @discardableResult
    static func save(_ config: DoorConfig) -> Bool {
        DoorConfigStore().save(config)
    }
}

@MainActor
final class DoorConnectionSaveModel: ObservableObject {
    @Published private(set) var errorMessage: String?

    private let store: DoorConfigStore

    init(store: DoorConfigStore = DoorConfigStore()) {
        self.store = store
    }

    func save(_ config: DoorConfig, onSaved: (DoorConfig) -> Void) {
        guard store.save(config) else {
            errorMessage = "The Door connection could not be saved. Your working connection is unchanged."
            return
        }
        errorMessage = nil
        onSaved(config)
    }
}
