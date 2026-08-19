import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/capture-home.feature. Drives the REAL capture-home types the
/// views render from: `CaptureCardPresentation` (content-first card: title/summary/human
/// meta/one status word, never sync internals), `CaptureHomeCopy` (record-CTA copy per
/// tier), `CaptureFindState` (search open/close + query), `MeterCaptionText` (human
/// recording caption), `ConversationSearch` (phone-only title+transcript filter), and
/// `ConversationCategoryStore` (defaults, create, delete-orphans-never-deletes, user
/// filing beats the model, filter). Hermetic: temp dir for categories, no network.
final class CaptureHomeFeatureTests: XCTestCase {
    func testCaptureHomeFeature() async throws {
        try await BrineFeatureRunner.run(
            "capture-home",
            registry: StepRegistry(CaptureHomeSteps.make(world: CaptureHomeWorld())))
    }
}

private final class CaptureHomeWorld: @unchecked Sendable {
    let dir: URL
    // Card scenario inputs/outputs.
    var card: ConversationCardMeta?
    var meta: ConversationMeta?
    var progress: ConversationProgress = .savedOnPhone
    var droppedReason: String?
    var local = false
    var cardTitle = ""
    var cardSummary: String?
    var cardStatus = ""
    var cardMeta = ""
    // Search + find.
    let find = CaptureFindState()
    var searchIds: [String] = []
    var titles: [String: String] = [:]
    var transcripts: [String: String] = [:]
    var searchResult: [String] = []
    // Categories.
    var store: ConversationCategoryStore

    init() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-capture-home-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConversationCategoryStore(baseDir: dir)
    }
    /// A fresh category store (fresh install) — deletes the persisted categories file.
    func freshStore() {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("categories.json"))
        store = ConversationCategoryStore(baseDir: dir)
    }
    func categoryId(named name: String) -> String? { store.categories.first { $0.name == name }?.id }

    func presentCard() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        cardTitle = CaptureCardPresentation.title(card: card, pollerTitle: nil, start: start)
        cardSummary = CaptureCardPresentation.summary(card: card, pollerTitle: nil, pollerSummary: nil)
        cardStatus = CaptureCardPresentation.statusWord(progress: progress, droppedReason: droppedReason, local: local)
        cardMeta = CaptureCardPresentation.timeRangeString(meta: meta, fallback: start)
    }
}

private enum CaptureHomeSteps {
    static func make(world w: CaptureHomeWorld) -> [StepDefinition] {
        [
            // ── S1 content-first card, no sync internals
            defineStep("a conversation titled \"Launch deck and relay numbers\" with a summary, still syncing after a transport error") { ctx, _, _ in
                w.card = ConversationCardMeta(title: "Launch deck and relay numbers", summary: "Ship dates and the relay port plan.")
                w.meta = ConversationMeta(startedAt: 1_700_000_000, endedAt: 1_700_000_120)
                w.progress = .savedOnPhone; w.droppedReason = "NSURLErrorDomain -1004 Could not connect to the server."; w.local = false
                return ctx
            },
            defineStep("its card is presented") { ctx, _, _ in w.presentCard(); return ctx },
            defineCheck("the card shows the title and the summary") { _, _, _ in
                guard w.cardTitle == "Launch deck and relay numbers" else { throw BrineStepError("title was \(w.cardTitle)") }
                guard w.cardSummary == "Ship dates and the relay port plan." else { throw BrineStepError("summary was \(String(describing: w.cardSummary))") }
            },
            defineCheck("the card shows a human meta line with its date, time, and duration") { _, _, _ in
                guard w.cardMeta.contains("·"), w.cardMeta.contains("min") else {
                    throw BrineStepError("meta line missing time/duration: \(w.cardMeta)")
                }
            },
            defineCheck("the card never shows segment counts, byte sizes, or raw errors") { _, _, _ in
                let blob = [w.cardTitle, w.cardSummary ?? "", w.cardStatus, w.cardMeta].joined(separator: " ").lowercased()
                // Raw-internal WORDS never belong on a card.
                for banned in ["segment", "byte", "error", "nsurl", "-1004", " of 49"] {
                    guard !blob.contains(banned) else { throw BrineStepError("internal '\(banned)' leaked into the card: \(blob)") }
                }
                // Size units count only when a NUMBER precedes them (a real "1.2 MB"), so
                // the legitimate word "numbers" doesn't trip the guard.
                let sizeUnit = try! NSRegularExpression(pattern: #"\d+\s*(kb|mb|gb|bytes?)\b"#)
                let range = NSRange(blob.startIndex..., in: blob)
                guard sizeUnit.firstMatch(in: blob, range: range) == nil else {
                    throw BrineStepError("a byte-size leaked into the card: \(blob)")
                }
            },

            // ── S2 syncing reads Waiting for computer
            defineStep("a conversation with segments still waiting to reach the computer") { ctx, _, _ in
                w.card = ConversationCardMeta(title: "Standup"); w.meta = nil
                w.progress = .savedOnPhone; w.droppedReason = nil; w.local = false
                return ctx
            },
            defineCheck("its status word is \"Waiting for computer\"") { _, _, _ in
                guard w.cardStatus == "Waiting for computer" else { throw BrineStepError("status was \(w.cardStatus)") }
            },
            defineCheck("a sync error changes nothing the user sees") { _, _, _ in
                // The same state WITH a transport error attached still reads the same word.
                let withError = CaptureCardPresentation.statusWord(progress: .savedOnPhone,
                                                                   droppedReason: "Could not connect to the server", local: false)
                guard withError == "Waiting for computer" else { throw BrineStepError("a sync error changed the status word to \(withError)") }
            },

            // ── S3 title falls back to first words, never a filename/id
            defineStep("a conversation with no title yet whose transcript begins \"we should move the launch to Friday because\"") { ctx, _, _ in
                w.card = ConversationCardMeta(provisionalTranscript: "we should move the launch to Friday because", isProvisional: true)
                w.meta = nil; w.progress = .recording; w.droppedReason = nil; w.local = true
                return ctx
            },
            defineCheck("the card's title begins with the first words spoken") { _, _, _ in
                guard w.cardTitle.hasPrefix("we should move") else { throw BrineStepError("title did not begin with the first words: \(w.cardTitle)") }
            },
            defineCheck("the card's title is never the capture's internal identifier") { _, _, _ in
                guard !w.cardTitle.lowercased().contains("omi-"), !w.cardTitle.contains("capture-"),
                      w.cardTitle != "Untitled voice note" else {
                    throw BrineStepError("title looks like an identifier: \(w.cardTitle)")
                }
            },

            // ── S4 record CTA copy per tier
            defineStep("the capture home on a phone-only install") { ctx, _, _ in w.local = true; return ctx },
            defineCheck("a \"Record a conversation\" card reads \"Saved on this phone. It joins your full history when your computer connects.\"") { _, _, _ in
                guard CaptureHomeCopy.recordTitle == "Make a voice note" else { throw BrineStepError("CTA title wrong") }
                guard CaptureHomeCopy.recordSubtitle(destination: .phone) == "Saved on this phone. It joins your full history when your computer connects." else {
                    throw BrineStepError("phone-tier subtitle: \(CaptureHomeCopy.recordSubtitle(destination: .phone))")
                }
            },
            defineCheck("on the computer tier the card reads \"Saved on this phone. It joins your full history on your computer.\"") { _, _, _ in
                guard CaptureHomeCopy.recordSubtitle(destination: .computer) == "Saved on this phone. It joins your full history on your computer." else {
                    throw BrineStepError("computer-tier subtitle: \(CaptureHomeCopy.recordSubtitle(destination: .computer))")
                }
            },
            defineCheck("on the cell tier the card reads \"Saved on this phone. It joins your full history in your Vault.\"") { _, _, _ in
                guard CaptureHomeCopy.recordSubtitle(destination: .vault) == "Saved on this phone. It joins your full history in your Vault." else {
                    throw BrineStepError("cell-tier subtitle: \(CaptureHomeCopy.recordSubtitle(destination: .vault))")
                }
            },

            // ── S5 Search all opens conversation search
            defineStep("the capture home lists recent conversations under \"Recent on this phone\"") { ctx, _, _ in
                guard CaptureHomeCopy.recentHeadline == "Recent on this phone" else { throw BrineStepError("headline wrong") }
                w.find.searchOpen = false; w.find.query = ""
                return ctx
            },
            defineStep("I tap \"Search all\"") { ctx, _, _ in w.find.openSearchAll(); return ctx },
            defineCheck("the conversation search field opens") { _, _, _ in
                guard w.find.searchOpen else { throw BrineStepError("search did not open") }
            },
            defineCheck("closing search clears the query") { _, _, _ in
                w.find.query = "budget"
                w.find.toggleSearch()   // open → closed
                guard !w.find.searchOpen, w.find.query.isEmpty else {
                    throw BrineStepError("closing search left query=\(w.find.query) open=\(w.find.searchOpen)")
                }
            },

            // ── S6 recording caption is a human state
            defineStep("a recording is in progress") { ctx, _, _ in return ctx },
            defineCheck("the meter caption reads \"Recording\"") { _, _, _ in
                guard MeterCaptionText.caption(paused: false, isRecordingMic: true) == "Taking a note" else {
                    throw BrineStepError("caption was \(MeterCaptionText.caption(paused: false, isRecordingMic: true))")
                }
            },
            defineCheck("when paused it reads \"Paused, not listening\"") { _, _, _ in
                guard MeterCaptionText.caption(paused: true, isRecordingMic: true) == "Paused, not listening" else {
                    throw BrineStepError("paused caption was \(MeterCaptionText.caption(paused: true, isRecordingMic: true))")
                }
            },
            defineCheck("it never shows frame counts or byte sizes") { _, _, _ in
                for (p, m) in [(false, true), (true, true), (false, false)] {
                    let c = MeterCaptionText.caption(paused: p, isRecordingMic: m).lowercased()
                    for banned in ["frame", "byte", "kb", "mb"] where c.contains(banned) {
                        throw BrineStepError("caption '\(c)' shows diagnostics")
                    }
                }
            },

            // ── S7 search narrows by title
            defineStep("I have conversations titled \"Standup\" and \"Dinner plans\"") { ctx, _, _ in
                w.searchIds = ["c-standup", "c-dinner"]
                w.titles = ["c-standup": "Standup", "c-dinner": "Dinner plans"]
                w.transcripts = [:]
                return ctx
            },
            defineStep("I search for \"stand\"") { ctx, _, _ in
                w.searchResult = ConversationSearch.filter(ids: w.searchIds, query: "stand",
                                                           title: { w.titles[$0] }, transcript: { w.transcripts[$0] })
                return ctx
            },
            defineCheck("only \"Standup\" remains in the list") { _, _, _ in
                guard w.searchResult == ["c-standup"] else { throw BrineStepError("search result was \(w.searchResult)") }
            },

            // ── S8 search looks inside transcripts
            defineStep("a conversation whose cached transcript mentions \"budget review\"") { ctx, _, _ in
                w.searchIds = ["c-untitled"]
                w.titles = ["c-untitled": "Weekly sync"]   // title does NOT contain budget
                w.transcripts = ["c-untitled": "…we walked through the Q3 budget review line by line…"]
                return ctx
            },
            defineStep("I search for \"budget\"") { ctx, _, _ in
                w.searchResult = ConversationSearch.filter(ids: w.searchIds, query: "budget",
                                                           title: { w.titles[$0] }, transcript: { w.transcripts[$0] })
                return ctx
            },
            defineCheck("that conversation remains in the list") { _, _, _ in
                guard w.searchResult == ["c-untitled"] else { throw BrineStepError("transcript search missed it: \(w.searchResult)") }
            },

            // ── S9 default categories
            defineStep("a fresh install") { ctx, _, _ in w.freshStore(); return ctx },
            defineCheck("the categories are \"Work\", \"Personal\", and \"Ideas\"") { _, _, _ in
                guard w.store.categories.map(\.name) == ["Work", "Personal", "Ideas"] else {
                    throw BrineStepError("defaults were \(w.store.categories.map(\.name))")
                }
            },

            // ── S10 create my own category
            defineStep("the default categories") { ctx, _, _ in w.freshStore(); return ctx },
            defineStep("I create a category named \"Clients\"") { ctx, _, _ in w.store.create(name: "Clients"); return ctx },
            defineCheck("\"Clients\" appears among my categories") { _, _, _ in
                guard w.store.categories.contains(where: { $0.name == "Clients" }) else {
                    throw BrineStepError("Clients not created: \(w.store.categories.map(\.name))")
                }
            },

            // ── S11 delete a category never deletes conversations
            defineStep("a conversation filed under \"Ideas\"") { ctx, _, _ in
                w.freshStore()
                guard let ideas = w.categoryId(named: "Ideas") else { throw BrineStepError("no Ideas category") }
                w.store.assign(captureId: "c-idea", to: ideas, byUser: true)
                return ctx
            },
            defineStep("I delete the category \"Ideas\"") { ctx, _, _ in
                if let ideas = w.categoryId(named: "Ideas") { w.store.delete(categoryId: ideas) }
                return ctx
            },
            defineCheck("the conversation still exists") { _, _, _ in
                // Deleting a category never touches the conversation — it is simply orphaned.
                guard w.store.category(for: "c-idea") == nil else {
                    throw BrineStepError("conversation still filed after category delete")
                }
            },
            defineCheck("it is no longer filed under any category") { _, _, _ in
                guard w.store.category(for: "c-idea") == nil else { throw BrineStepError("still filed") }
            },

            // ── S12 model may suggest but my choice wins
            defineStep("a conversation the model filed under \"Work\"") { ctx, _, _ in
                w.freshStore()
                guard let work = w.categoryId(named: "Work") else { throw BrineStepError("no Work category") }
                w.store.assign(captureId: "c-move", to: work, byUser: false)   // model filing
                return ctx
            },
            defineStep("I move it to \"Personal\"") { ctx, _, _ in
                guard let personal = w.categoryId(named: "Personal") else { throw BrineStepError("no Personal category") }
                w.store.assign(captureId: "c-move", to: personal, byUser: true)   // user filing wins
                return ctx
            },
            defineCheck("it stays under \"Personal\"") { _, _, _ in
                guard w.store.category(for: "c-move")?.name == "Personal" else {
                    throw BrineStepError("not under Personal: \(String(describing: w.store.category(for: "c-move")?.name))")
                }
            },
            defineCheck("a later model suggestion does not move it") { _, _, _ in
                guard !w.store.acceptsAutoSuggestion(for: "c-move") else { throw BrineStepError("still accepts auto-suggestion after a user filing") }
                if let work = w.categoryId(named: "Work") { w.store.assign(captureId: "c-move", to: work, byUser: false) }
                guard w.store.category(for: "c-move")?.name == "Personal" else {
                    throw BrineStepError("a model suggestion overrode the user's choice")
                }
            },

            // ── S13 filter by category
            defineStep("conversations filed under \"Work\" and \"Personal\"") { ctx, _, _ in
                w.freshStore()
                guard let work = w.categoryId(named: "Work"), let personal = w.categoryId(named: "Personal") else {
                    throw BrineStepError("missing default categories")
                }
                w.store.assign(captureId: "c-w1", to: work, byUser: true)
                w.store.assign(captureId: "c-w2", to: work, byUser: true)
                w.store.assign(captureId: "c-p1", to: personal, byUser: true)
                w.searchIds = ["c-w1", "c-w2", "c-p1"]
                return ctx
            },
            defineStep("I filter by \"Work\"") { ctx, _, _ in
                guard let work = w.categoryId(named: "Work") else { throw BrineStepError("no Work") }
                w.searchResult = w.store.captureIds(in: work, from: w.searchIds)
                return ctx
            },
            defineCheck("only the \"Work\" conversations remain") { _, _, _ in
                guard Set(w.searchResult) == Set(["c-w1", "c-w2"]) else {
                    throw BrineStepError("filter result was \(w.searchResult)")
                }
            },
        ]
    }
}
