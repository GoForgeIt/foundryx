import XCTest
import Foundation
import FoundryXKit

/// Capture home: search + categories (features/capture-home.feature, track
/// 20260713T0902). The UI filters PURELY through ConversationSearch and
/// ConversationCategoryStore; these tests pin the durable pieces.
final class CaptureHomeTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("foundryx-categories-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: search

    // Scenario: searching narrows the list by title
    func testSearchFiltersByTitle() {
        let ids = ConversationSearch.filter(
            ids: ["a", "b"],
            query: "stand",
            title: { $0 == "a" ? "Standup" : "Dinner plans" },
            transcript: { _ in nil })
        XCTAssertEqual(ids, ["a"])
    }

    // Scenario: searching also looks inside transcripts on my phone
    func testSearchFiltersByCachedTranscript() {
        let ids = ConversationSearch.filter(
            ids: ["a", "b"],
            query: "budget",
            title: { _ in "Untitled" },
            transcript: { $0 == "b" ? "…the budget review moved to Tuesday…" : nil })
        XCTAssertEqual(ids, ["b"])
    }

    // Empty query = no filtering (the search field at rest hides nothing).
    func testEmptyQueryKeepsEverything() {
        let ids = ConversationSearch.filter(
            ids: ["a", "b"], query: "  ",
            title: { _ in nil }, transcript: { _ in nil })
        XCTAssertEqual(ids, ["a", "b"])
    }

    // MARK: categories

    // Scenario: default categories are ready on first run
    func testDefaultCategoriesOnFirstRun() throws {
        let store = ConversationCategoryStore(baseDir: try tempDir())
        XCTAssertEqual(store.categories.map(\.name), ["Work", "Personal", "Ideas"])
    }

    // Scenario: I can create my own category
    func testCreateCategory() throws {
        let dir = try tempDir()
        let store = ConversationCategoryStore(baseDir: dir)
        _ = store.create(name: "Clients")
        XCTAssertTrue(store.categories.map(\.name).contains("Clients"))
        // …and it survives a relaunch.
        XCTAssertTrue(ConversationCategoryStore(baseDir: dir).categories.map(\.name).contains("Clients"))
    }

    // Creating a duplicate (case-insensitive) returns the existing category.
    func testCreateDuplicateReturnsExisting() throws {
        let store = ConversationCategoryStore(baseDir: try tempDir())
        let a = store.create(name: "Clients")
        let b = store.create(name: "clients")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(store.categories.filter { $0.name.lowercased() == "clients" }.count, 1)
    }

    // Scenario: deleting a category never deletes conversations
    func testDeleteCategoryOrphansAssignmentsOnly() throws {
        let store = ConversationCategoryStore(baseDir: try tempDir())
        let ideas = store.categories.first { $0.name == "Ideas" }!
        store.assign(captureId: "c1", to: ideas.id, byUser: true)
        store.delete(categoryId: ideas.id)
        XCTAssertNil(store.category(for: "c1"), "conversation is uncategorized, not gone")
        XCTAssertFalse(store.categories.contains { $0.id == ideas.id })
    }

    // Scenario: the model may suggest a category but my choice wins
    func testUserAssignmentBeatsAutoForever() throws {
        let store = ConversationCategoryStore(baseDir: try tempDir())
        let work = store.categories.first { $0.name == "Work" }!
        let personal = store.categories.first { $0.name == "Personal" }!

        store.assign(captureId: "c1", to: work.id, byUser: false)      // the model files it
        XCTAssertEqual(store.category(for: "c1")?.id, work.id)

        store.assign(captureId: "c1", to: personal.id, byUser: true)   // I move it
        XCTAssertEqual(store.category(for: "c1")?.id, personal.id)

        store.assign(captureId: "c1", to: work.id, byUser: false)      // later suggestion
        XCTAssertEqual(store.category(for: "c1")?.id, personal.id,
                       "a later model suggestion never moves a user-filed conversation")
    }

    // Auto-assign only fills a blank; renaming keeps assignments.
    func testRenameKeepsAssignments() throws {
        let store = ConversationCategoryStore(baseDir: try tempDir())
        let work = store.categories.first { $0.name == "Work" }!
        store.assign(captureId: "c1", to: work.id, byUser: true)
        store.rename(categoryId: work.id, to: "Client work")
        XCTAssertEqual(store.category(for: "c1")?.name, "Client work")
    }

    // Scenario: filtering by category shows only that category
    func testFilterByCategory() throws {
        let store = ConversationCategoryStore(baseDir: try tempDir())
        let work = store.categories.first { $0.name == "Work" }!
        let personal = store.categories.first { $0.name == "Personal" }!
        store.assign(captureId: "c1", to: work.id, byUser: true)
        store.assign(captureId: "c2", to: personal.id, byUser: true)
        store.assign(captureId: "c3", to: work.id, byUser: false)

        XCTAssertEqual(store.captureIds(in: work.id, from: ["c1", "c2", "c3"]).sorted(),
                       ["c1", "c3"])
    }

    // Corrupt store file → defaults, never a crash.
    func testCorruptStoreFallsBackToDefaults() throws {
        let dir = try tempDir()
        try Data("not json".utf8).write(to: dir.appendingPathComponent("categories.json"))
        let store = ConversationCategoryStore(baseDir: dir)
        XCTAssertEqual(store.categories.map(\.name), ["Work", "Personal", "Ideas"])
    }

    // MARK: waveform thumbnails

    // The row thumbnail derives from real segment sizes (opus bytes ≈ voice energy).
    func testWaveformProfileBucketsSizes() {
        let profile = WaveformThumb.profile(sizes: [10, 10, 100, 100, 10, 10, 100, 100],
                                            buckets: 4)
        XCTAssertEqual(profile.count, 4)
        XCTAssertEqual(profile[0], profile[2], "equal-energy buckets normalize equally")
        XCTAssertGreaterThan(profile[1], profile[0])
        XCTAssertLessThanOrEqual(profile.max() ?? 0, 1.0)
    }

    // Empty input → empty profile (no fake waveform; the card draws no line — T1 AC4).
    func testWaveformProfileEmptyStaysEmpty() {
        XCTAssertTrue(WaveformThumb.profile(sizes: [], buckets: 8).isEmpty)
    }

    // AC7: genuinely varied REAL amplitude is returned UNCHANGED — the seed never
    // overwrites real data (the "honest, never interpolated" contract holds).
    func testWaveformProfileKeepsRealVariedData() {
        let sizes = [10, 90, 20, 100, 15, 80]
        let profile = WaveformThumb.profile(sizes: sizes, buckets: 6, seed: "cap-real")
        XCTAssertEqual(profile.count, 6)
        // The real bucket shape (normalized by peak) is preserved, not replaced.
        let peak = Double(sizes.max()!)
        XCTAssertEqual(profile, sizes.map { Double($0) / peak })
    }

    // AC4: a DEGENERATE profile (near-uniform / all-equal segments) falls back to a
    // seeded VARIED shape — never a flat line.
    func testWaveformProfileSeedsNearUniform() {
        let profile = WaveformThumb.profile(sizes: [50, 50, 50, 50], buckets: 8, seed: "cap-flat")
        XCTAssertGreaterThan(profile.count, 1, "degenerate → a full seeded shape, not one flat bar")
        let spread = (profile.max() ?? 0) - (profile.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.15, "the seeded fallback is visibly varied")
    }

    // A single-segment (≤1 bucket) profile is degenerate → seeded varied shape, not one bar.
    func testWaveformProfileSeedsSingleSegment() {
        let profile = WaveformThumb.profile(sizes: [50], buckets: 8, seed: "cap-single")
        XCTAssertGreaterThan(profile.count, 1)
        let spread = (profile.max() ?? 0) - (profile.min() ?? 0)
        XCTAssertGreaterThan(spread, 0.15)
    }

    // The seed is DETERMINISTIC: same capture id → same fallback waveform (no per-render jitter).
    func testWaveformSeedIsDeterministic() {
        let a = WaveformThumb.profile(sizes: [50, 50, 50], buckets: 8, seed: "cap-x")
        let b = WaveformThumb.profile(sizes: [50, 50, 50], buckets: 8, seed: "cap-x")
        XCTAssertEqual(a, b)
        let c = WaveformThumb.profile(sizes: [50, 50, 50], buckets: 8, seed: "cap-y")
        XCTAssertNotEqual(a, c, "different capture ids seed distinct shapes")
    }
}
