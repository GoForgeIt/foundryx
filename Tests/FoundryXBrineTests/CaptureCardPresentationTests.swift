import XCTest
@testable import FoundryXKit

/// Capture home, content-first cards (features/capture-home.feature, track
/// 20260714T1800 ux_prototype_realignment). `CaptureCardPresentation` is the ONE
/// pure struct the card view renders from, built through the REAL builder from the
/// same inputs the view holds (WAL snapshot, ConversationMeta, card tombstone,
/// poller state) — so these step-defs pin what the card can possibly show.
/// Engineering telemetry (segment counts, byte totals, raw transport errors) can
/// never render because the presentation simply has no field carrying it.
final class CaptureCardPresentationTests: XCTestCase {

    // A conversation from Tue Jul 14 2026 4:16 PM to 4:18 PM (local formatters
    // render the exact strings; the assertions below stay timezone-safe by
    // re-deriving expectations through the same public formatter).
    private let start: UInt64 = 1_784_074_560
    private let end: UInt64 = 1_784_074_680

    private func status(stage: CaptureStage, total: Int = 5, synced: Int = 5,
                        streaming: Bool = false, syncError: String? = nil) -> CaptureStatus {
        CaptureStatus(id: "cap-20260714T161600-abcdef", stage: stage,
                      totalSegments: total, syncedSegments: synced, bytes: 43_210,
                      startedAt: Date(timeIntervalSince1970: TimeInterval(start)),
                      streaming: streaming, lastSyncError: syncError)
    }

    private func present(status: CaptureStatus,
                         meta: ConversationMeta? = nil,
                         card: ConversationCardMeta? = nil,
                         pollerStage: CaptureLifecycleStage = .stored,
                         pollerTitle: String? = nil,
                         pollerSummary: String? = nil,
                         droppedReason: String? = nil,
                         hasCachedTranscript: Bool = false,
                         local: Bool = false,
                         categoryName: String? = nil,
                         categoryAutoFiled: Bool = false,
                         waveform: [Double] = []) -> CaptureCardPresentation {
        CaptureCardPresentation.make(
            status: status, meta: meta, card: card,
            pollerStage: pollerStage, pollerTitle: pollerTitle,
            pollerSummary: pollerSummary, droppedReason: droppedReason,
            hasCachedTranscript: hasCachedTranscript, local: local,
            categoryName: categoryName, categoryAutoFiled: categoryAutoFiled,
            waveform: waveform)
    }

    /// Everything the card can possibly render, joined — the "rendered text" the
    /// scenario asserts against.
    private func renderedText(_ p: CaptureCardPresentation) -> String {
        [p.title, p.summaryLine ?? "", p.statusWord, p.metaLine, p.categoryLabel ?? ""]
            .joined(separator: " · ")
    }

    // MARK: Scenario: a conversation card shows its title and summary, never sync internals

    func testCardShowsTitleAndSummaryNeverSyncInternals() {
        // Still syncing (3/5), a raw transport error pending — the worst case that
        // used to leak "3/5 segments synced · 42.2 KB · DoorError error 0".
        let p = present(
            status: status(stage: .savedOnPhone, total: 5, synced: 3,
                           syncError: "DoorError error 0 — HTTP 502"),
            meta: ConversationMeta(startedAt: start, endedAt: end),
            card: ConversationCardMeta(title: "Launch deck and relay numbers",
                                       summary: "Sarah finishes the appendix tonight; send her the deck Friday at 9:00 AM."))

        XCTAssertEqual(p.title, "Launch deck and relay numbers")
        XCTAssertEqual(p.summaryLine,
                       "Sarah finishes the appendix tonight; send her the deck Friday at 9:00 AM.")

        let text = renderedText(p)
        for forbidden in ["segments synced", "KB", "DoorError", "HTTP", "3/5", "error 0"] {
            XCTAssertFalse(text.contains(forbidden),
                           "card leaked engineering telemetry: \(forbidden) in \(text)")
        }
    }

    // And the card shows a human meta line with its date, time, and duration
    func testMetaLineIsHumanDateTimeRangeDuration() {
        let meta = ConversationMeta(startedAt: start, endedAt: end)
        let p = present(status: status(stage: .savedToComputer), meta: meta)
        // Same public formatter the card uses → "Tue, Jul 14 · 4:16 PM–4:18 PM · 2 min".
        XCTAssertEqual(p.metaLine,
                       CaptureCardPresentation.timeRangeString(
                           meta: meta, fallback: Date(timeIntervalSince1970: TimeInterval(start))))
        XCTAssertTrue(p.metaLine.contains("–"), "meta line carries the time range")
        XCTAssertTrue(p.metaLine.contains("2 min"), "meta line carries the duration")
    }

    // Place joins the same quiet line when known.
    func testMetaLineAppendsPlace() {
        let meta = ConversationMeta(startedAt: start, endedAt: end,
                                    location: ConversationLocation(lat: 0, long: 0, label: "Office"))
        let p = present(status: status(stage: .savedToComputer), meta: meta)
        XCTAssertTrue(p.metaLine.hasSuffix(" · Office"))
    }

    // MARK: Scenario: a syncing conversation reads Waiting for computer

    func testSyncingConversationReadsWaitingForComputer() {
        let p = present(status: status(stage: .savedOnPhone, total: 5, synced: 2))
        XCTAssertEqual(p.statusWord, "Waiting for computer")
    }

    // And a sync error changes nothing the user sees
    func testSyncErrorChangesNothingTheUserSees() {
        let clean = present(status: status(stage: .savedOnPhone, total: 5, synced: 2))
        let errored = present(status: status(stage: .savedOnPhone, total: 5, synced: 2,
                                             syncError: "DoorError error 0 — Socket is not connected"))
        XCTAssertEqual(clean.statusWord, errored.statusWord)
        XCTAssertEqual(renderedText(clean), renderedText(errored),
                       "a transport error is a log line, never card copy")
    }

    // The rest of the human word ladder.
    func testStatusWordLadder() {
        XCTAssertEqual(present(status: status(stage: .recording, total: 0, synced: 0,
                                              streaming: true)).statusWord,
                       "Taking a note")
        XCTAssertEqual(present(status: status(stage: .savedToComputer)).statusWord,
                       "Saved to computer")
        XCTAssertEqual(present(status: status(stage: .savedToComputer),
                               pollerStage: .transcribing).statusWord,
                       "Transcribing")
        XCTAssertEqual(present(status: status(stage: .savedToComputer),
                               pollerStage: .organized).statusWord,
                       "Ready")
        // Phone-only tier: there is no computer — the words stay on-device.
        XCTAssertEqual(present(status: status(stage: .savedOnPhone, synced: 2), local: true).statusWord,
                       "Saved on this phone")
    }

    // A failed capture reads as a human word, never a raw reason interpolation.
    func testFailureIsHumanNeverRawReason() {
        let dropped = present(status: status(stage: .savedToComputer),
                              pollerStage: .failed, droppedReason: "silent_no_transcript")
        XCTAssertEqual(dropped.statusWord, "No speech detected")
        let unknown = present(status: status(stage: .savedToComputer),
                              pollerStage: .failed, droppedReason: "kiln_oom_137")
        XCTAssertEqual(unknown.statusWord, "Needs review",
                       "an unrecognized failure reason degrades to a human word, not an interpolation")
        XCTAssertFalse(renderedText(unknown).contains("kiln_oom_137"))
    }

    // MARK: Scenario: a card's title falls back to the first words spoken, never a filename

    func testTitleFallsBackToFirstWordsSpoken() {
        let p = present(
            status: status(stage: .savedOnPhone, synced: 2),
            card: ConversationCardMeta(
                provisionalTranscript: "we should move the launch to Friday because the relay numbers land Thursday",
                isProvisional: true))
        XCTAssertTrue(p.title.hasPrefix("we should move the launch"),
                      "title starts with the first words spoken, got \(p.title)")
        XCTAssertFalse(p.title.contains("cap-20260714T161600-abcdef"),
                       "a capture id is never a title")
    }

    func testTitleNeverTheCaptureId() {
        // Nothing known at all — still never the internal identifier.
        let p = present(status: status(stage: .savedOnPhone, synced: 2))
        XCTAssertFalse(p.title.contains("cap-20260714T161600-abcdef"))
        XCTAssertFalse(p.title.isEmpty, "the card always has a human title")
    }

    // MARK: category pill

    func testCategoryLabelMarksAutoFiling() {
        let auto = present(status: status(stage: .savedToComputer),
                           categoryName: "Work", categoryAutoFiled: true)
        XCTAssertEqual(auto.categoryLabel, "Work, auto")
        let chosen = present(status: status(stage: .savedToComputer),
                             categoryName: "Work", categoryAutoFiled: false)
        XCTAssertEqual(chosen.categoryLabel, "Work")
        XCTAssertNil(present(status: status(stage: .savedToComputer)).categoryLabel)
    }

    // MARK: Scenario: the record CTA describes where audio is saved

    func testRecordCTACopy() {
        XCTAssertEqual(CaptureHomeCopy.recordTitle, "Make a voice note")
        XCTAssertEqual(CaptureHomeCopy.recordSubtitle(destination: .phone),
                       "Saved on this phone. It joins your full history when your computer connects.")
        XCTAssertEqual(CaptureHomeCopy.recordSubtitle(destination: .computer),
                       "Saved on this phone. It joins your full history on your computer.")
        // The cell tier is a FIRST-CLASS destination: a Vault owner must never be told
        // the history lives "on your computer".
        XCTAssertEqual(CaptureHomeCopy.recordSubtitle(destination: .vault),
                       "Saved on this phone. It joins your full history in your Vault.")
    }

    // "Recent on this phone · N conversations" headline + the Search all action.
    func testRecentHeadlineCopy() {
        XCTAssertEqual(CaptureHomeCopy.recentHeadline, "Recent on this phone")
        XCTAssertEqual(CaptureHomeCopy.conversationCount(1), "1 voice note")
        XCTAssertEqual(CaptureHomeCopy.conversationCount(5), "5 voice notes")
        XCTAssertEqual(CaptureHomeCopy.searchAll, "Search all")
    }

    // MARK: Scenario: Search all opens conversation search

    func testSearchAllOpensConversationSearch() {
        let find = CaptureFindState()
        XCTAssertFalse(find.searchOpen)
        find.openSearchAll()
        XCTAssertTrue(find.searchOpen, "Search all opens the same search field")
        // Idempotent — a second tap keeps it open (never toggles it shut).
        find.openSearchAll()
        XCTAssertTrue(find.searchOpen)
    }

    // And closing search clears the query
    func testClosingSearchClearsQuery() {
        let find = CaptureFindState()
        find.openSearchAll()
        find.query = "relay"
        find.toggleSearch()   // the header icon closes it
        XCTAssertFalse(find.searchOpen)
        XCTAssertEqual(find.query, "", "a stale query never filters a reopened list")
        find.toggleSearch()   // …and reopens it clean
        XCTAssertTrue(find.searchOpen)
    }

    // MARK: Scenario: the recording caption reads a human state, not diagnostics

    func testMeterCaptionIsHuman() {
        XCTAssertEqual(MeterCaptionText.caption(paused: false, isRecordingMic: true), "Taking a note")
        XCTAssertEqual(MeterCaptionText.caption(paused: false, isRecordingMic: false), "Listening…")
        XCTAssertEqual(MeterCaptionText.caption(paused: true, isRecordingMic: true),
                       "Paused, not listening")
        for caption in [MeterCaptionText.caption(paused: false, isRecordingMic: true),
                        MeterCaptionText.caption(paused: false, isRecordingMic: false)] {
            XCTAssertFalse(caption.contains("frames"), "no frame counts on the instrument")
            XCTAssertFalse(caption.contains("B"), "no byte sizes on the instrument")
        }
    }
}
