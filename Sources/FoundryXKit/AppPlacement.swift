// AppPlacement — where you were, kept, so coming back continues instead of restarting.
//
// WHY THIS FILE EXISTS
// --------------------
// Nick, on device (2026-08-04):
//
//   "anytime i refocus or go away from the app and come back it doesnt keep me on the page
//    i was — it takes me back to the list of conversations which is a huge pain in the
//    butt…. It should keep me where I was so i can continue whatever I was working on
//    whether that's looking at a specific transcript, being in the middle of a chat, etc"
//
// MEASURED, not assumed (PlaceRestoreProofUITests, run against the pre-fix app):
//
//   • home → return (the process SUSPENDS)  → the tab AND the open transcript both survive.
//     SwiftUI keeps its own state across a suspend; nothing was broken on that path.
//   • the process is RECLAIMED and relaunched → the tab is `Capture` and nothing is open.
//     `AppTab.launch` is Capture, and Capture is "the list of conversations". Exactly the
//     sentence Nick wrote.
//
// So the place was never STORED anywhere; it only ever lived in `TabRouter`'s memory and in
// SwiftUI `@State`. Anything that ends that memory — iOS reclaiming a backgrounded app that
// holds BLE + audio + a large library, or `RootView` rebuilding the whole tab tree because
// its `MainTabs` identity key changed (`MainTabsIdentity`, below: the key carries the door
// bearer, so an id_token refresh on return is a full remount) — puts you back on the list.
// One durable record fixes both, because both end with `MainTabs.init` running again.
//
// WHAT THIS FILE IS
// -----------------
// The value (`AppPlacement`), where it is kept (`AppPlacementStore`, inside the ACCOUNT root
// so a place can never leak across identities), and the pure decision about whether a saved
// place is still somewhere you can honestly be put (`AppPlacementRestore.resolve`). Restoring
// into a conversation that was deleted, or into a Mac sheet with no Mac to reach, is not
// "keeping your place" — it is an empty shell. Every one of those cases degrades to the list
// and SAYS WHY.

import Foundation

/// Where the person was: which tab, and what was open on it.
public struct AppPlacement: Codable, Equatable, Sendable {
    /// The bottom-nav tab that was showing.
    public var tab: AppTab
    /// The conversation whose transcript detail was pushed on the Capture tab.
    public var openCaptureId: String?
    /// The chat conversation that was live on the Chat tab.
    public var openChatId: String?
    /// The "on your Mac" library sheet was open over the Chat tab.
    public var macLibraryOpen: Bool
    /// The identity generation this was recorded under. A place recorded by one
    /// account is never handed to another.
    public var generation: UInt64
    /// Recorded on the door-backed tier (a computer/cell brain) rather than phone-only.
    public var doorTier: Bool

    public init(tab: AppTab,
                openCaptureId: String? = nil,
                openChatId: String? = nil,
                macLibraryOpen: Bool = false,
                generation: UInt64,
                doorTier: Bool) {
        self.tab = tab
        self.openCaptureId = openCaptureId
        self.openChatId = openChatId
        self.macLibraryOpen = macLibraryOpen
        self.generation = generation
        self.doorTier = doorTier
    }

    /// The place with everything openable dropped — the tab's own list.
    public func atTheList() -> AppPlacement {
        var out = self
        out.openCaptureId = nil
        out.openChatId = nil
        out.macLibraryOpen = false
        return out
    }
}

/// Why a saved place could not be restored as written. `.none` means it was.
public enum AppPlacementFallback: String, Codable, Equatable, Sendable, CaseIterable {
    /// Restored exactly as saved.
    case none
    /// Nothing was ever saved (first launch after installing this) — the launch tab.
    case nothingSaved
    /// Saved by a different account. Never shown to this one.
    case differentAccount
    /// Saved on a different tier (door-backed vs phone-only) — a different corpus.
    case differentTier
    /// The conversation whose transcript was open has been deleted.
    case captureGone
    /// The chat conversation that was live has been deleted.
    case chatGone
    /// The Mac library sheet was open, and the Mac is not reachable now.
    case doorUnreachable

    /// What the person is told, in their words, when their place could not be kept.
    /// `nil` where there is nothing to explain (the place WAS kept, or there never
    /// was one). Never a code, never a shrug — it names the thing that is gone.
    public var notice: String? {
        switch self {
        case .none, .nothingSaved:
            return nil
        case .differentAccount:
            return "This is a different account, so we started you at the beginning."
        case .differentTier:
            return "Where your conversations live changed, so this is the list."
        case .captureGone:
            return "That conversation isn't here anymore, so this is the list."
        case .chatGone:
            return "That chat isn't here anymore, so this is your chats."
        case .doorUnreachable:
            return "Your computer isn't reachable, so this is your chats."
        }
    }
}

/// Where to actually land, and whether that is the saved place or an honest fallback.
public struct AppPlacementResolution: Equatable, Sendable {
    public let placement: AppPlacement
    public let fallback: AppPlacementFallback

    public init(placement: AppPlacement, fallback: AppPlacementFallback) {
        self.placement = placement
        self.fallback = fallback
    }

    /// What to tell the person, if anything.
    public var notice: String? { fallback.notice }
}

/// The pure decision: given a saved place and the world as it is now, where do we put
/// this person? Nothing here touches disk or UI — the shell hands in what it knows.
public enum AppPlacementRestore {

    /// The place a person with no saved place lands: the launch tab, nothing open.
    public static func launchPlacement(generation: UInt64, doorTier: Bool) -> AppPlacement {
        AppPlacement(tab: AppTab.launch, generation: generation, doorTier: doorTier)
    }

    /// Resolve a saved place against the world.
    ///
    /// - `saved`: what was written last time (nil ⇒ nothing was).
    /// - `generation`: the identity generation live NOW.
    /// - `doorTier`: whether this launch is door-backed (computer/cell) or phone-only.
    /// - `doorConnected`: whether the computer is actually reachable right now.
    /// - `captureExists` / `chatExists`: does that conversation still exist? Asked only
    ///   for the one id we would restore into, never over the whole library.
    public static func resolve(
        saved: AppPlacement?,
        generation: UInt64,
        doorTier: Bool,
        doorConnected: Bool,
        captureExists: (String) -> Bool,
        chatExists: (String) -> Bool
    ) -> AppPlacementResolution {
        let launch = launchPlacement(generation: generation, doorTier: doorTier)

        guard let saved else {
            return AppPlacementResolution(placement: launch, fallback: .nothingSaved)
        }
        // A place belongs to the account that made it. Someone else's place is not a
        // fallback candidate — it is discarded whole, tab included.
        guard saved.generation == generation else {
            return AppPlacementResolution(placement: launch, fallback: .differentAccount)
        }
        // The tier decides WHICH corpus the surfaces read. A place recorded against the
        // other one names things this launch cannot open, so keep the tab and drop the rest.
        guard saved.doorTier == doorTier else {
            var out = saved.atTheList()
            out.doorTier = doorTier
            return AppPlacementResolution(placement: out, fallback: .differentTier)
        }

        var out = saved

        // The Mac sheet needs a Mac. Drop it before anything else so an unreachable door
        // is reported as itself and not mistaken for a missing conversation.
        if out.macLibraryOpen, !(doorTier && doorConnected) {
            out.macLibraryOpen = false
            return AppPlacementResolution(placement: out, fallback: .doorUnreachable)
        }
        if let captureId = out.openCaptureId, !captureExists(captureId) {
            out.openCaptureId = nil
            return AppPlacementResolution(placement: out, fallback: .captureGone)
        }
        if let chatId = out.openChatId, !chatExists(chatId) {
            out.openChatId = nil
            return AppPlacementResolution(placement: out, fallback: .chatGone)
        }
        return AppPlacementResolution(placement: out, fallback: .none)
    }
}

// MARK: - Where it is kept

/// The place, on disk, inside the ACCOUNT root — the same root the chat list and the
/// captures live in, so signing out / deleting an account takes the place with it and no
/// account can ever be handed another's place.
///
/// Reads are memoised because `MainTabs.init` runs speculatively on ordinary parent
/// redraws (its own comments say so), and an uncached JSON read per body pass is exactly
/// the main-actor pathology `ResidualMainActorWorkTests` exists to catch.
public enum AppPlacementStore {

    public static func url(inAccountRoot root: URL) -> URL {
        root.appendingPathComponent("app-placement.json")
    }

    private static let lock = NSLock()
    /// path → the last value read or written there (`.some(nil)` = read, found nothing).
    nonisolated(unsafe) private static var cache: [String: AppPlacement?] = [:]

    public static func load(inAccountRoot root: URL) -> AppPlacement? {
        let url = Self.url(inAccountRoot: root)
        lock.lock()
        if let hit = cache[url.path] { lock.unlock(); return hit }
        lock.unlock()

        let decoded: AppPlacement? = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(AppPlacement.self, from: $0) }

        lock.lock()
        cache[url.path] = .some(decoded)
        lock.unlock()
        return decoded
    }

    @discardableResult
    public static func save(_ placement: AppPlacement, inAccountRoot root: URL) -> Bool {
        let url = Self.url(inAccountRoot: root)
        lock.lock()
        // An unchanged place is not worth a write — the tab publisher fires on every
        // redraw that touches it.
        if let hit = cache[url.path], hit == placement { lock.unlock(); return true }
        cache[url.path] = .some(placement)
        lock.unlock()

        guard let data = try? JSONEncoder().encode(placement) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Forget a place entirely (account deletion / sign-out paths, and tests).
    public static func clear(inAccountRoot root: URL) {
        let url = Self.url(inAccountRoot: root)
        lock.lock()
        cache[url.path] = .some(nil)
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop the memoised reads (tests that write the file behind the store's back).
    public static func forgetCachedReadsForTests() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    /// Does that conversation still exist?
    ///
    /// Asked of the DISK, not of the in-memory library. A capture is a directory under the
    /// account root (`CaptureWAL` writes `root/<captureId>/`), so this answers correctly at
    /// mount — before the library has hydrated. Asking the hydrating list instead would
    /// report every conversation as deleted for the first second of every launch, which is
    /// the exact "honest fallback" that would be a lie.
    public static func captureExists(_ captureId: String, inAccountRoot root: URL) -> Bool {
        guard !captureId.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        let path = root.appendingPathComponent(captureId, isDirectory: true).path
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

// MARK: - Why a suspend is not the only way to lose your place

/// The identity `RootView` gives the whole tab tree. SwiftUI rebuilds a view — every
/// `@StateObject` it owns, `TabRouter` included — when its `.id` changes, so this string
/// IS the answer to "can the place survive without being written down?".
///
/// It carries the door BEARER, and the bearer is the phone's OIDC id_token, which expires
/// about hourly: a 401 on return triggers a silent refresh, the refreshed token rebuilds
/// the target, the key changes, and every tab is constructed from scratch — no suspend, no
/// termination, same landing on the conversation list. Extracted here (from an inline
/// expression in `RootView`) so that fact is assertable instead of merely commented.
public enum MainTabsIdentity {
    /// The door-backed (computer) tier.
    public static func computerKey(tunnelId: String?, bearer: String, generation: UInt64) -> String {
        (tunnelId ?? "remote") + "#" + String(bearer.suffix(12)) + "#acct-\(generation)"
    }

    /// The hosted-cell tier.
    public static func cellKey(url: String, bearer: String, generation: UInt64) -> String {
        "cell#" + url + "#" + String(bearer.suffix(12)) + "#acct-\(generation)"
    }

    /// The phone-only tier (no door, so no bearer).
    public static func phoneKey(generation: UInt64) -> String {
        "local-brain#acct-\(generation)"
    }
}
