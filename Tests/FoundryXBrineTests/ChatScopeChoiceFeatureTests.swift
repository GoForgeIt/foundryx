import XCTest
import Foundation
import BrineSwiftCore
@testable import FoundryXKit

/// Brine driver for features/chat-scope-choice.feature.
///
/// Two halves, both real:
///
///   * The WORDS are the kit's own — `ChatScope` / `ChatScopeCopy` / `ChatListOrganizer` /
///     `KilnLibraryCopy` — driven directly, never restated as string constants here.
///   * The WIRING lives in `App/`, which `swift test` cannot compile, so it is read from
///     source through `AppSourceTree` (comments stripped, string literals kept). That is
///     this suite's existing convention for App-side facts; see
///     `VoiceNotesLanguageFeatureTests` and `RecordingSurfaceRenderingLedgerTests`.
///
/// The predicate the copy is held to (`ChatScope.isBareQuantifier`) is itself checked against
/// a POSITIVE control inside the scenario — the exact label this change removed. A rule that
/// could never fire would make every copy check vacuous.
final class ChatScopeChoiceFeatureTests: XCTestCase {
    func testChatScopeChoiceFeature() async throws {
        try await BrineFeatureRunner.run(
            "chat-scope-choice",
            registry: StepRegistry(ChatScopeChoiceSteps.make(world: ChatScopeChoiceWorld())))
    }
}

// MARK: - the world

private final class ChatScopeChoiceWorld: @unchecked Sendable {

    /// `App/<file>` → its source with comments removed and string literals intact.
    var sources: [String: String] = [:]
    /// The scopes the header offers once the control is open.
    var offered: [ChatScope] = []
    /// The scope the reader chose.
    var chosen: ChatScope?
    /// A real library row, seeded by the pick-up scenario.
    var imported: LibraryChatRow?

    static let chatScreen = "App/ChatScreen.swift"
    static let libraryView = "App/KilnLibraryView.swift"
    static let conversationView = "App/KilnConversationView.swift"

    /// The chat surface: the screen itself plus the two sheets it opens onto.
    static let chatSurfaceFiles = [chatScreen, libraryView, conversationView]

    func loadChatSurface() throws {
        for path in Self.chatSurfaceFiles {
            let url = AppSourceTree.repoRoot.appendingPathComponent(path)
            let text = try String(contentsOf: url, encoding: .utf8)
            // A guard, not a convenience: a moved or renamed file must be a LOUD failure,
            // never an empty string that satisfies every "does not contain" check below.
            guard text.count > 500 else {
                throw BrineStepError("\(path) read back only \(text.count) bytes")
            }
            sources[path] = AppSourceTree.withoutComments(of: text)
        }
    }

    func source(_ path: String) throws -> String {
        guard let text = sources[path] else {
            throw BrineStepError("\(path) was never loaded — the Given did not run")
        }
        return text
    }

    /// Every single-line string literal in `text`, contents only.
    static func stringLiterals(in text: String) -> [String] {
        let pattern = #""([^"\\\n]*(?:\\.[^"\\\n]*)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Lines of `text` matching `pattern`, as `line-number: text` for a usable failure.
    static func lines(in text: String, matching pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let ns = line as NSString
            let hit = regex.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length)) != nil
            return hit ? "\(index + 1): \(line.trimmingCharacters(in: .whitespaces))" : nil
        }
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }
}

// MARK: - steps

private enum ChatScopeChoiceSteps {
    static func make(world w: ChatScopeChoiceWorld) -> [StepDefinition] {
        [
            // ── Given ────────────────────────────────────────────────────────────────

            defineStep("I am on the chat surface") { ctx, _, _ in
                try w.loadChatSurface()
                w.offered = []
                w.chosen = nil
                return ctx
            },

            defineStep(
                "Kiln's library holds a chat imported from Claude Code that I have not picked up"
            ) { ctx, _, _ in
                try w.loadChatSurface()
                w.imported = LibraryChatRow(
                    id: "import:claude-code:foundryx:wf_ae593755-e61:abbdae8d72a12b0fc",
                    title: "Wire the library into the phone",
                    origin: "claude-code",
                    startedAt: "2026-08-01T12:00:00Z",
                    lastMessagePreview: "Picking this back up on the phone.",
                    lastMessageAt: "2026-08-01T12:40:00Z",
                    importProjectRoot: "/Users/nick/Development/foundryx",
                    resumed: false)
                return ctx
            },

            // ── When ─────────────────────────────────────────────────────────────────

            defineStep("I open the control for choosing which chats to look at") { ctx, _, _ in
                // The header renders `ChatScope.allCases` — this IS what opening it shows.
                w.offered = ChatScope.allCases
                guard !w.offered.isEmpty else {
                    throw BrineStepError("the control offers no choices at all")
                }
                return ctx
            },

            defineStep("I choose the chats on my Mac") { ctx, _, _ in
                w.offered = ChatScope.allCases
                guard let mac = w.offered.first(where: { $0 == .onYourMac }) else {
                    throw BrineStepError("no choice leads to the Mac")
                }
                w.chosen = mac
                return ctx
            },

            // ── one control, not two lookalikes ──────────────────────────────────────

            defineCheck("there is a single control for choosing which chats to look at") {
                _, _, _ in
                let screen = try w.source(ChatScopeChoiceWorld.chatScreen)
                let n = ChatScopeChoiceWorld.occurrences(
                    of: "accessibilityIdentifier(ChatScopeCopy.controlAccessibilityIdentifier)",
                    in: screen)
                guard n == 1 else {
                    throw BrineStepError(
                        "expected exactly one \"\(ChatScopeCopy.controlAccessibilityIdentifier)\" "
                            + "control on the chat header, found \(n)")
                }
                // It must be driven from the kit's case list, so a corpus cannot be added
                // without also being named and captioned.
                guard screen.contains("ChatScope.allCases") else {
                    throw BrineStepError(
                        "the header does not render ChatScope.allCases — the choices are "
                            + "spelled inline again, which is how the two-button pair came back")
                }
            },

            defineCheck("it does not sit beside a second control that opens chats") { _, _, _ in
                let screen = try w.source(ChatScopeChoiceWorld.chatScreen)
                // The defect, exactly: a header BUTTON whose action opens one of the two
                // sheets. Both sheets are now opened only from `open(_:)`, which the single
                // menu calls.
                let siblings = try ChatScopeChoiceWorld.lines(
                    in: screen,
                    matching: #"(GrainButton|^\s*Button)\s*\(.*showing(Chats|KilnLibrary)"#)
                guard siblings.isEmpty else {
                    throw BrineStepError(
                        "a second header control opens a chat corpus:\n"
                            + siblings.joined(separator: "\n"))
                }
                for (state, count) in [
                    ("showingChats = true", ChatScopeChoiceWorld.occurrences(
                        of: "showingChats = true", in: screen)),
                    ("showingKilnLibrary = true", ChatScopeChoiceWorld.occurrences(
                        of: "showingKilnLibrary = true", in: screen)),
                ] where count != 1 {
                    throw BrineStepError(
                        "\(state) is set from \(count) places, expected exactly one")
                }
            },

            // ── the choices name the two places ──────────────────────────────────────

            defineCheck("I can choose the chats on this phone") { _, _, _ in
                guard w.offered.contains(.thisPhone) else {
                    throw BrineStepError("no choice leads to this phone's own chats")
                }
                guard ChatScope.thisPhone.title.localizedCaseInsensitiveContains("phone") else {
                    throw BrineStepError(
                        "\"\(ChatScope.thisPhone.title)\" does not say it is this phone")
                }
                let screen = try w.source(ChatScopeChoiceWorld.chatScreen)
                let wired = try ChatScopeChoiceWorld.lines(
                    in: screen, matching: #"case\s+\.thisPhone:\s*showingChats\s*=\s*true"#)
                guard !wired.isEmpty else {
                    throw BrineStepError(
                        "choosing this phone does not open this phone's chat list")
                }
            },

            defineCheck("I can choose the chats on my Mac") { _, _, _ in
                guard w.offered.contains(.onYourMac) else {
                    throw BrineStepError("no choice leads to the chats on the Mac")
                }
                guard ChatScope.onYourMac.title.localizedCaseInsensitiveContains("mac") else {
                    throw BrineStepError(
                        "\"\(ChatScope.onYourMac.title)\" does not say it is the Mac")
                }
                let screen = try w.source(ChatScopeChoiceWorld.chatScreen)
                let wired = try ChatScopeChoiceWorld.lines(
                    in: screen,
                    matching: #"case\s+\.onYourMac:\s*showingKilnLibrary\s*=\s*true"#)
                guard !wired.isEmpty else {
                    throw BrineStepError(
                        "choosing the Mac does not open Kiln's shared library")
                }
            },

            defineCheck("neither choice is labelled with a bare quantifier") { _, _, _ in
                // POSITIVE CONTROL FIRST. If the rule cannot fire, every use of it below is
                // vacuous — and "All" is the precise label this change removed.
                guard ChatScope.isBareQuantifier("All") else {
                    throw BrineStepError(
                        "the bare-quantifier rule does not even reject \"All\" — it cannot fail, "
                            + "so it proves nothing about the labels")
                }
                guard !ChatScope.isBareQuantifier(ChatScope.onYourMac.title) else {
                    throw BrineStepError("the rule is broken: it rejects a real place name")
                }
                let offenders = w.offered
                    .filter { ChatScope.isBareQuantifier($0.title) }
                    .map(\.title)
                guard offenders.isEmpty else {
                    throw BrineStepError("choices labelled with a bare quantifier: \(offenders)")
                }
            },

            defineCheck("every choice says what I would be looking at") { _, _, _ in
                for scope in w.offered {
                    let caption = scope.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !caption.isEmpty else {
                        throw BrineStepError("\"\(scope.title)\" says nothing about what is behind it")
                    }
                    guard caption != scope.title else {
                        throw BrineStepError("\"\(scope.title)\" only repeats its own label")
                    }
                }
                let captions = w.offered.map(\.caption)
                guard Set(captions).count == captions.count else {
                    throw BrineStepError("two choices say the same thing: \(captions)")
                }
                // And the header must actually render them — a caption nobody shows is not
                // said at the point of choice.
                let screen = try w.source(ChatScopeChoiceWorld.chatScreen)
                guard screen.contains("scope.caption") else {
                    throw BrineStepError("the header never renders a choice's caption")
                }
            },

            defineCheck("the choice for my Mac names Kiln, Claude Code and Codex") { _, _, _ in
                let caption = ChatScope.onYourMac.caption
                let missing = ["Kiln", "Claude Code", "Codex"]
                    .filter { !caption.localizedCaseInsensitiveContains($0) }
                guard missing.isEmpty else {
                    throw BrineStepError(
                        "\"\(caption)\" does not name \(missing.joined(separator: ", "))")
                }
            },

            // ── "All" means one thing ────────────────────────────────────────────────

            defineCheck("no control on that surface is labelled \"All\"") { _, _, _ in
                var offenders: [String] = []
                for path in ChatScopeChoiceWorld.chatSurfaceFiles {
                    let text = try w.source(path)
                    offenders += ChatScopeChoiceWorld.stringLiterals(in: text)
                        .filter(ChatScope.isBareQuantifier)
                        .map { "\(path): \"\($0)\"" }
                }
                guard offenders.isEmpty else {
                    throw BrineStepError(
                        "bare-quantifier labels still on the chat surface:\n"
                            + offenders.joined(separator: "\n"))
                }
            },

            defineCheck(
                "\"All\" is still offered as a filter over the chats this phone started"
            ) { _, _, _ in
                // The chip is untouched — with the header button gone it is unambiguous,
                // and removing it would have been a different (and worse) change.
                guard ChatListOrganizer.Provenance.allCases.contains(.all),
                      ChatListOrganizer.Provenance.all.rawValue == "All" else {
                    throw BrineStepError(
                        "the phone-local list no longer offers its All filter: "
                            + "\(ChatListOrganizer.Provenance.allCases.map(\.rawValue))")
                }
            },

            // ── the destination ──────────────────────────────────────────────────────

            defineCheck("the screen I land on is titled for my Mac") { _, _, _ in
                guard w.chosen == .onYourMac else {
                    throw BrineStepError("the Mac was never chosen")
                }
                let library = try w.source(ChatScopeChoiceWorld.libraryView)
                guard library.contains("navigationTitle(ChatScope.onYourMac.title)") else {
                    throw BrineStepError(
                        "Kiln's library is not titled with the scope the reader chose")
                }
                guard ChatScope.onYourMac.title.localizedCaseInsensitiveContains("mac") else {
                    throw BrineStepError(
                        "\"\(ChatScope.onYourMac.title)\" does not say whose chats these are")
                }
            },

            defineCheck("it is not titled with a bare quantifier") { _, _, _ in
                guard !ChatScope.isBareQuantifier(ChatScope.onYourMac.title) else {
                    throw BrineStepError("the library title is a bare quantifier")
                }
                let library = try w.source(ChatScopeChoiceWorld.libraryView)
                let quantified = ChatScopeChoiceWorld.stringLiterals(in: library).filter {
                    $0.lowercased().hasPrefix("all ")
                }
                guard quantified.isEmpty else {
                    throw BrineStepError(
                        "the library still counts rather than names: \(quantified)")
                }
            },

            // ── the pick-up path, still reachable ────────────────────────────────────

            defineCheck("that chat is marked as one I can pick up") { _, _, _ in
                guard let row = w.imported else {
                    throw BrineStepError("no imported chat was seeded")
                }
                let notice = KilnConversationNotice.make(row)
                guard notice.offersPickUp else {
                    throw BrineStepError(
                        "an unresumed Claude Code import is not offered a pick-up")
                }
                let library = try w.source(ChatScopeChoiceWorld.libraryView)
                guard library.contains("notice.offersPickUp") else {
                    throw BrineStepError(
                        "the library row never reads offersPickUp, so nothing marks the "
                            + "rows that can be picked up")
                }
            },

            // The pick-up used to be a BUTTON on this screen, and this check used to assert
            // that button's presence. It is now what SENDING does: an imported chat that has
            // never been picked up is resumed in place on its first turn, so the reader types
            // and carries on. That is a stronger claim than "a button exists" — it names the
            // wire behaviour — and it is asserted end to end in features/mac-chat-in-place.
            defineCheck("opening it lets me carry on by typing, with nothing to press first") { _, _, _ in
                guard let row = w.imported else {
                    throw BrineStepError("no imported chat was seeded")
                }
                let opened = KilnConversationPresentation.open(row, turns: [])
                guard opened.sendPlan == .resumeInPlaceThenSend else {
                    throw BrineStepError(
                        "an unresumed Claude Code import does not resume on its first turn — "
                            + "so typing would not carry it on (plan: \(opened.sendPlan))")
                }
                let detail = try w.source(ChatScopeChoiceWorld.conversationView)
                guard detail.contains("ChatSurface(") else {
                    throw BrineStepError(
                        "the chat detail does not render the shared chat surface, so it has "
                            + "no composer to type into")
                }
                guard !detail.contains("KilnLibraryCopy.pickUpAction") else {
                    throw BrineStepError(
                        "the chat detail still puts a pick-up button where the composer "
                            + "belongs — that ceremony is exactly what is being removed")
                }
                // Removing the button must not remove the FACT it carried.
                guard detail.contains("KilnLibraryCopy.pickUpBlurb") else {
                    throw BrineStepError(
                        "nothing says that carrying on resumes this same chat rather than "
                            + "copying it")
                }
            },

            defineCheck("a chat I already picked up is not offered again") { _, _, _ in
                guard let row = w.imported else {
                    throw BrineStepError("no imported chat was seeded")
                }
                let picked = LibraryChatRow(
                    id: row.id, title: row.title, origin: row.origin,
                    startedAt: row.startedAt,
                    lastMessagePreview: row.lastMessagePreview,
                    lastMessageAt: row.lastMessageAt,
                    importProjectRoot: row.importProjectRoot,
                    resumed: true)
                guard !KilnConversationNotice.make(picked).offersPickUp else {
                    throw BrineStepError("an already-resumed chat is offered a second pick-up")
                }
            },
        ]
    }
}
