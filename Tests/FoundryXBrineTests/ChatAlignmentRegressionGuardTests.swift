import XCTest
import Foundation

/// T-PHONE-CHATLAW's alignment guard (tracks.md): "a user turn is right-aligned and an
/// assistant turn left-aligned in BOTH `ChatView` and `LocalChatScreen`, and this
/// assertion passes on today's tree for `ChatView` BY DESIGN, so it is asserted only as
/// a guard that the header rebuild did not break it, and the track's falsification must
/// prove that guard can still go red."
///
/// This is explicitly NOT new work — the earlier draft's "correct ChatView's all-left
/// alignment" deliverable is DROPPED (tracks.md, T-PHONE-CHATLAW): `ChatView` already
/// delegates shape AND alignment to `GrainMessageBubble`
/// (`grain/platforms/grain-swift/Sources/Grain/Components/Chat/GrainMessageBubble.swift`),
/// which already puts a `Spacer` BEFORE the text for `.user` (pushing it right) and
/// AFTER it for `.assistant` (pushing it left). What this file adds is the REGRESSION
/// GUARD tracks.md asks for, plus the falsification that proves it is not vacuous.
///
/// Two things this file deliberately does NOT do:
///  - It does not touch `GrainMessageBubble`'s box styling (fill/border on either role).
///    That is `T-GRAIN-SHAPES`'s "no boxed left turns" law, and `T-GRAIN-SHAPES` is
///    explicit that the composer/bubble-shape work is "Web only." Extending this guard
///    to assert "no box on assistant" would silently absorb a DIFFERENT track's scope.
///  - It does not attempt full hosted-view pixel geometry (unlike
///    `MacChatInPlaceFeatureTests`'s `layOutChatSurface`, which proves layout SIZE, not
///    per-element frames). SwiftUI does not expose a stable, cross-OS-version API for
///    reading an individual `Text`'s frame out of a hosted subtree by accessibility
///    identifier, and the track's OWN falsification method is source-level ("remove the
///    `.user` Spacer … in a scratch build and require the guard to go red naming
///    `ChatView`") — this file matches that method exactly, reading the real vendored
///    grain source the same way `AppSourceTree` reads `App/`.
final class ChatAlignmentRegressionGuardTests: XCTestCase {

    /// The vendored grain package's `GrainMessageBubble.swift` — resolved the same way
    /// `Package.swift` resolves it (`.package(name: "Grain", path:
    /// "../grain/platforms/grain-swift")`), i.e. a sibling of this repo's root.
    private static func grainMessageBubbleSource() throws -> String {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repoRoot.deleteLastPathComponent() }   // Tests/FoundryXBrineTests/… → repo root
        let path = repoRoot
            .deletingLastPathComponent()                        // → parent of this repo
            .appendingPathComponent("grain/platforms/grain-swift/Sources/Grain/Components/Chat/GrainMessageBubble.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// The chat law's structural shape: does a `Spacer` appear BEFORE `Text(text)` for
    /// `role == .user` (pushing user turns right), and AFTER it for `role == .assistant`
    /// (pushing assistant turns left)? Returns nil for either flag if the source doesn't
    /// match the expected `HStack { … Text(text) … }` shape at all (fails loud rather
    /// than defaulting to "aligned").
    struct AlignmentShape: Equatable {
        let userSpacerBeforeText: Bool
        let assistantSpacerAfterText: Bool
    }

    static func alignmentShape(in source: String) -> AlignmentShape? {
        guard let textRange = source.range(of: "Text(text)") else { return nil }
        let before = source[source.startIndex..<textRange.lowerBound]
        let after = source[textRange.upperBound...]
        // Scoped to the same HStack body (up to the closing brace of `body`), not the
        // whole file, so an unrelated Spacer elsewhere (e.g. inside `bubbleShape`)
        // cannot produce a false positive.
        let userBeforeUser = before.range(of: "role == .user")
        let userBeforeSpacer = before.range(of: "Spacer(")
        let userSpacerBeforeText = userBeforeUser != nil && userBeforeSpacer != nil
            && userBeforeUser!.lowerBound < userBeforeSpacer!.lowerBound
        let closingBrace = after.range(of: "\n    }") ?? (after.endIndex..<after.endIndex)
        let scopedAfter = after[..<closingBrace.lowerBound]
        let assistantAfterAssistant = scopedAfter.range(of: "role == .assistant")
        let assistantAfterSpacer = scopedAfter.range(of: "Spacer(")
        let assistantSpacerAfterText = assistantAfterAssistant != nil && assistantAfterSpacer != nil
            && assistantAfterAssistant!.lowerBound < assistantAfterSpacer!.lowerBound
        return AlignmentShape(userSpacerBeforeText: userSpacerBeforeText,
                              assistantSpacerAfterText: assistantSpacerAfterText)
    }

    /// Scenario: a user turn is right-aligned and an assistant turn is left-aligned in
    /// `ChatView` (which every chat surface in the app renders through — see below).
    /// This PASSES ON TODAY'S TREE BY DESIGN (tracks.md) — it is a guard, not new work.
    func testGrainMessageBubbleAlignsUserRightAndAssistantLeft() throws {
        let source = try Self.grainMessageBubbleSource()
        guard let shape = Self.alignmentShape(in: source) else {
            XCTFail("GrainMessageBubble.swift no longer matches the expected " +
                    "HStack { … Text(text) … } shape — the guard cannot read it")
            return
        }
        XCTAssertTrue(shape.userSpacerBeforeText,
                      "GrainMessageBubble no longer pushes .user text right (no leading " +
                      "Spacer for role == .user) — ChatView's user turns would render left")
        XCTAssertTrue(shape.assistantSpacerAfterText,
                      "GrainMessageBubble no longer pushes .assistant text left (no " +
                      "trailing Spacer for role == .assistant) — ChatView's assistant " +
                      "turns would render right, alongside the user's")
    }

    /// Scenario: `ChatView` calls `GrainMessageBubble` with the CORRECT role for each
    /// branch — `.assistant` for `msg.role == "assistant"`, `.user` for the else branch
    /// — so the alignment law above is actually reachable from what ships, not just
    /// true of the component in isolation.
    func testChatViewPassesTheCorrectRoleForEachBranch() throws {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { repoRoot.deleteLastPathComponent() }
        let chatViewPath = repoRoot.appendingPathComponent("Sources/FoundryXKit/ChatView.swift")
        let source = try String(contentsOf: chatViewPath, encoding: .utf8)
        guard let assistantBranch = source.range(of: "msg.role == \"assistant\""),
              let elseBranch = source.range(of: "} else {") else {
            XCTFail("ChatView.swift no longer has the expected assistant/else branch shape")
            return
        }
        let assistantBody = source[assistantBranch.upperBound..<elseBranch.lowerBound]
        XCTAssertTrue(assistantBody.contains("GrainMessageBubble(role: .assistant"),
                      "the assistant branch does not pass role: .assistant to GrainMessageBubble")
        let elseBody = source[elseBranch.upperBound...]
        XCTAssertTrue(elseBody.contains("GrainMessageBubble(role: .user"),
                      "the user (else) branch does not pass role: .user to GrainMessageBubble")
    }

    /// Scenario: `LocalChatScreen` (the phone-only tier) renders through the SAME
    /// `ChatSurface` → `ChatView` → `GrainMessageBubble` path as `ChatScreen` — not a
    /// second bubble rendering of its own — so the alignment law above covers it too.
    /// `LocalChatScreen.swift`'s own header comment says as much ("The SAME chat state
    /// every other chat in the app is rendered from … used to keep its own state and
    /// draw plain paragraphs"); this asserts it structurally, extending
    /// `MacChatInPlaceFeatureTests`'s existing "neither screen builds a chat surface of
    /// its own" invariant (which named `ChatScreen.swift` and `KilnConversationView.swift`
    /// but not `LocalChatScreen.swift`) to close that gap.
    func testLocalChatScreenRendersThroughTheSharedChatSurfaceNotItsOwnBubbles() throws {
        let hosts = try AppSourceTree.filesReferencing("ChatSurface")
        XCTAssertTrue(hosts.contains("App/LocalChatScreen.swift"),
                      "LocalChatScreen.swift does not render through ChatSurface — it may " +
                      "have its own bubble rendering, which is exactly the two-tiers-disagree " +
                      "defect T-PHONE-CHATLAW's alignment guard exists to catch " +
                      "(found instead: \(hosts))")
        let direct = try AppSourceTree.filesReferencing("GrainMessageBubble")
        XCTAssertTrue(direct.isEmpty,
                      "GrainMessageBubble is referenced directly outside ChatSurface/ChatView " +
                      "in \(direct) — a second bubble rendering with its own (possibly " +
                      "different) alignment")
    }

    /// Falsification (tracks.md: "remove the `.user` Spacer from
    /// `GrainMessageBubble.swift:20` in a scratch build and require the guard to go red
    /// naming `ChatView`"). This proves the SAME parser this file's real assertions run
    /// through can detect that exact mutation, against an in-memory copy — not the real
    /// vendored file, which stays untouched.
    func testGuardDetectsTheNamedMutation_userSpacerRemoved() throws {
        let real = try Self.grainMessageBubbleSource()
        guard real.contains("if role == .user { Spacer(minLength: GrainSpacing.x8) }") else {
            XCTFail("the real source no longer contains the exact line this mutation removes " +
                    "— update the mutant to match the current source before trusting this guard")
            return
        }
        let mutant = real.replacingOccurrences(
            of: "if role == .user { Spacer(minLength: GrainSpacing.x8) }\n            ",
            with: "")
        guard let shape = Self.alignmentShape(in: mutant) else {
            XCTFail("the mutant no longer matches the expected shape at all")
            return
        }
        XCTAssertFalse(shape.userSpacerBeforeText,
                       "the guard did NOT detect the removed .user Spacer — it cannot go red " +
                       "for the regression tracks.md names, so per that track's own falsification " +
                       "clause it 'is measuring nothing and must be deleted rather than kept as " +
                       "a green row'")
    }
}
