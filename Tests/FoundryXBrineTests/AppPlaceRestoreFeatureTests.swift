import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/app-place-restore.feature.
///
/// Drives the REAL durable place — `AppPlacementStore` writing into a real account root on
/// disk, and `AppPlacementRestore.resolve` deciding where that place puts you — so "leave and
/// come back" is a genuine round trip through the file the app actually reads, not a variable
/// handed between two steps. "The app is reclaimed" and "I leave and come back" are the same
/// operation here on purpose: after a reclaim there is nothing in memory to fall back on, so
/// a step that reads the store proves the harder of the two.
final class AppPlaceRestoreFeatureTests: XCTestCase {
    func testAppPlaceRestoreFeature() async throws {
        try await BrineFeatureRunner.run(
            "app-place-restore",
            registry: StepRegistry(AppPlaceSteps.make(world: AppPlaceWorld())))
    }
}

private final class AppPlaceWorld: @unchecked Sendable {
    /// A real account root on disk — the place is written into it and read back out.
    let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-place-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var generation: UInt64 = 7
    var doorTier = true
    var doorConnected = true

    /// The world's conversations, by id. Deleting removes them here, exactly as the
    /// library and the chat store would.
    var captures: Set<String> = ["capture-a", "capture-b"]
    var chats: Set<String> = ["chat-a", "chat-b"]

    /// The landing decided by the last "come back".
    var landed: AppPlacementResolution?

    /// The `MainTabs` identity key before / after a token refresh.
    var identityBefore: String?
    var identityAfter: String?

    /// Brine reuses one world across a feature's scenarios, so every Given opens with a
    /// clean world — otherwise a conversation deleted in one scenario is still missing in
    /// the next and a later scenario passes or fails for the previous one's reason.
    func reset() {
        generation = 7
        doorTier = true
        doorConnected = true
        captures = ["capture-a", "capture-b"]
        chats = ["chat-a", "chat-b"]
        landed = nil
        identityBefore = nil
        identityAfter = nil
        AppPlacementStore.forgetCachedReadsForTests()
        AppPlacementStore.clear(inAccountRoot: root)
    }

    func record(_ placement: AppPlacement) {
        AppPlacementStore.forgetCachedReadsForTests()
        AppPlacementStore.save(placement, inAccountRoot: root)
    }

    /// Leaving and coming back: read the durable place off disk and resolve it against
    /// the world as it now is. The in-memory cache is dropped first so this is a real
    /// read of a real file — the thing a relaunched process does.
    func comeBack() {
        AppPlacementStore.forgetCachedReadsForTests()
        let saved = AppPlacementStore.load(inAccountRoot: root)
        landed = AppPlacementRestore.resolve(
            saved: saved,
            generation: generation,
            doorTier: doorTier,
            doorConnected: doorConnected,
            captureExists: { [captures] in captures.contains($0) },
            chatExists: { [chats] in chats.contains($0) })
    }

    var placement: AppPlacement? { landed?.placement }
}

private enum AppPlaceSteps {
    // swiftlint:disable:next function_body_length
    static func make(world w: AppPlaceWorld) -> [StepDefinition] {
        [
            defineStep("I am in a chat conversation") { ctx, _, _ in
                w.reset()
                w.record(AppPlacement(tab: .chat, openChatId: "chat-a",
                                      generation: w.generation, doorTier: w.doorTier))
                return ctx
            },
            defineStep("I am reading a conversation's transcript") { ctx, _, _ in
                w.reset()
                w.record(AppPlacement(tab: .capture, openCaptureId: "capture-a",
                                      generation: w.generation, doorTier: w.doorTier))
                return ctx
            },
            defineStep("I have my computer's chats open over the Chat tab") { ctx, _, _ in
                w.reset()
                w.record(AppPlacement(tab: .chat, openChatId: "chat-a", macLibraryOpen: true,
                                      generation: w.generation, doorTier: true))
                return ctx
            },
            defineStep("I am on the Chat tab on my computer's brain") { ctx, _, _ in
                w.reset()
                w.doorTier = true
                w.record(AppPlacement(tab: .chat, openChatId: "chat-a",
                                      generation: w.generation, doorTier: true))
                w.identityBefore = MainTabsIdentity.computerKey(
                    tunnelId: "mac-1", bearer: "aaaaaaaaaaaaTOKEN-ONE-1234",
                    generation: w.generation)
                return ctx
            },
            defineStep("I am reading a conversation's transcript on my computer's brain") { ctx, _, _ in
                w.reset()
                w.doorTier = true
                w.record(AppPlacement(tab: .capture, openCaptureId: "capture-a",
                                      generation: w.generation, doorTier: true))
                return ctx
            },
            defineStep("I come back on just my phone") { ctx, _, _ in
                w.doorTier = false        // the phone-only tier reads a different corpus
                w.doorConnected = false
                w.comeBack()
                return ctx
            },
            defineStep("I have never used the app before") { ctx, _, _ in
                w.reset()
                return ctx
            },

            defineStep("I leave the app and come back") { ctx, _, _ in
                w.comeBack(); return ctx
            },
            defineStep("I open the app") { ctx, _, _ in
                w.comeBack(); return ctx
            },
            defineStep("I come back") { ctx, _, _ in
                w.comeBack(); return ctx
            },
            defineStep("the app is reclaimed in the background and I open it again") { ctx, _, _ in
                // A reclaim leaves NOTHING in memory. The only difference from a suspend is
                // that the store is the sole source — which is what `comeBack` reads.
                w.comeBack(); return ctx
            },
            defineStep("that conversation is deleted while I am away") { ctx, _, _ in
                w.captures.remove("capture-a"); return ctx
            },
            defineStep("that chat is deleted while I am away") { ctx, _, _ in
                w.chats.remove("chat-a"); return ctx
            },
            defineStep("my computer is unreachable and I come back") { ctx, _, _ in
                w.doorConnected = false
                w.comeBack()
                return ctx
            },
            defineStep("a different account signs in and comes back") { ctx, _, _ in
                w.generation += 1     // a new identity generation IS a different account
                w.comeBack()
                return ctx
            },
            defineStep("my sign-in token is refreshed") { ctx, _, _ in
                w.identityAfter = MainTabsIdentity.computerKey(
                    tunnelId: "mac-1", bearer: "bbbbbbbbbbbbTOKEN-TWO-5678",
                    generation: w.generation)
                // The rebuilt tree runs `MainTabs.init` again, which reads the store.
                w.comeBack()
                return ctx
            },

            defineCheck("I am on the Chat tab") { _, _, _ in
                try expectTab(w, .chat)
            },
            defineCheck("I am on the Capture tab") { _, _, _ in
                try expectTab(w, .capture)
            },
            defineCheck("the same chat conversation is open") { _, _, _ in
                guard w.placement?.openChatId == "chat-a" else {
                    throw BrineStepError("open chat was \(String(describing: w.placement?.openChatId))")
                }
            },
            defineCheck("the same conversation's transcript is still open") { _, _, _ in
                guard w.placement?.openCaptureId == "capture-a" else {
                    throw BrineStepError(
                        "open transcript was \(String(describing: w.placement?.openCaptureId))")
                }
            },
            defineCheck("my computer's chats are still open") { _, _, _ in
                guard w.placement?.macLibraryOpen == true else {
                    throw BrineStepError("the computer's chats were not reopened")
                }
            },
            defineCheck("my computer's chats are not open") { _, _, _ in
                guard w.placement?.macLibraryOpen == false else {
                    throw BrineStepError("the computer's chats were reopened onto no computer")
                }
            },
            defineCheck("no transcript is open") { _, _, _ in
                guard w.placement?.openCaptureId == nil else {
                    throw BrineStepError(
                        "a transcript was restored: \(String(describing: w.placement?.openCaptureId))")
                }
            },
            defineCheck("no chat conversation is open") { _, _, _ in
                guard w.placement?.openChatId == nil else {
                    throw BrineStepError(
                        "a chat was restored: \(String(describing: w.placement?.openChatId))")
                }
            },
            defineCheck("I am not told anything went wrong") { _, _, _ in
                guard let landed = w.landed else { throw BrineStepError("nothing was resolved") }
                guard landed.notice == nil else {
                    throw BrineStepError("was told: \(landed.notice ?? "")")
                }
            },
            defineCheck("I am told {string}") { _, params, _ in
                let expected = try params.requireString(0)
                guard let landed = w.landed else { throw BrineStepError("nothing was resolved") }
                guard landed.notice == expected else {
                    throw BrineStepError(
                        "notice was \(landed.notice.map { "\"\($0)\"" } ?? "nothing"), "
                        + "expected \"\(expected)\"")
                }
            },
            defineCheck("my place is stored inside my own account's folder") { _, _, _ in
                let url = AppPlacementStore.url(inAccountRoot: w.root)
                guard url.deletingLastPathComponent().standardizedFileURL
                        == w.root.standardizedFileURL else {
                    throw BrineStepError("the place is kept at \(url.path), outside the account root")
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw BrineStepError("no place was written at \(url.path)")
                }
            },
            defineCheck("the tab tree is rebuilt from scratch") { _, _, _ in
                guard let before = w.identityBefore, let after = w.identityAfter else {
                    throw BrineStepError("no before/after identity key was taken")
                }
                guard before != after else {
                    throw BrineStepError(
                        "the tab-tree identity did not change on a token refresh (\(before)) — "
                        + "if that is now true, the remount path this feature covers is gone")
                }
            },
            defineCheck("my place is restored anyway") { _, _, _ in
                guard w.placement?.tab == .chat, w.placement?.openChatId == "chat-a" else {
                    throw BrineStepError(
                        "after the rebuild we landed on "
                        + "\(String(describing: w.placement?.tab))/"
                        + "\(String(describing: w.placement?.openChatId))")
                }
                guard w.landed?.notice == nil else {
                    throw BrineStepError("a rebuild is not a fallback: \(w.landed?.notice ?? "")")
                }
            },
        ]
    }

    private static func expectTab(_ w: AppPlaceWorld, _ expected: AppTab) throws {
        guard let landed = w.landed else { throw BrineStepError("nothing was resolved") }
        guard landed.placement.tab == expected else {
            throw BrineStepError("landed on \(landed.placement.tab), expected \(expected)")
        }
    }
}
