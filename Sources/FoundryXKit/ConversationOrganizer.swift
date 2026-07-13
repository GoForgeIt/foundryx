// ConversationOrganizer — search, categories, and row thumbnails for the capture
// home (track 20260713T0902, features/capture-home.feature).
//
//  • ConversationSearch: pure filter over what the PHONE holds (titles + locally
//    cached transcripts) — it never pretends to reach further.
//  • ConversationCategoryStore: user-controlled categories with model suggestions.
//    Defaults ship; create/rename/delete are the user's; deleting a category
//    orphans its conversations (never deletes them); a user's own filing beats
//    any model suggestion, forever.
//  • WaveformThumb: a row's waveform profile from real segment sizes (opus bytes
//    track voice energy — the same property the door's VAD uses).
//  • CategoryAutoTagger: the seam the on-device model fills; the store only
//    accepts its suggestion where the user hasn't spoken.

import Foundation

// MARK: - Search

public enum ConversationSearch {
    /// Case-insensitive substring filter over titles and locally cached
    /// transcripts. Blank query = no filtering. Order preserved.
    public static func filter(
        ids: [String],
        query: String,
        title: (String) -> String?,
        transcript: (String) -> String?
    ) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ids }
        return ids.filter { id in
            if let t = title(id), t.localizedCaseInsensitiveContains(q) { return true }
            if let body = transcript(id), body.localizedCaseInsensitiveContains(q) { return true }
            return false
        }
    }
}

// MARK: - Categories

public struct ConversationCategory: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
}

/// The seam the on-device model fills (FM-gated in the app). Pure suggestion —
/// returns the NAME of one of the offered categories or nil; the store decides
/// whether it may land (a user filing always wins).
public protocol CategoryAutoTagger: Sendable {
    func suggest(title: String?, transcript: String?, from categories: [ConversationCategory]) async -> String?
}

public final class ConversationCategoryStore: ObservableObject {
    public static let defaultNames = ["Work", "Personal", "Ideas"]

    private struct Assignment: Codable, Equatable {
        var categoryId: String
        var byUser: Bool
    }
    private struct State: Codable {
        var categories: [ConversationCategory]
        var assignments: [String: Assignment]
    }

    @Published public private(set) var categories: [ConversationCategory] = []
    private var assignments: [String: Assignment] = [:]
    private let url: URL

    public init(baseDir: URL) {
        self.url = baseDir.appendingPathComponent("categories.json")
        load()
    }

    // MARK: CRUD (the user's)

    /// Creates a category; a duplicate name (case-insensitive) returns the
    /// existing one instead of forking it.
    @discardableResult
    public func create(name: String) -> ConversationCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = categories.first(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            return existing
        }
        let cat = ConversationCategory(id: UUID().uuidString, name: trimmed)
        categories.append(cat)
        save()
        return cat
    }

    public func rename(categoryId: String, to newName: String) {
        guard let i = categories.firstIndex(where: { $0.id == categoryId }) else { return }
        categories[i].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Deleting a category orphans its conversations (uncategorized), never
    /// deletes them.
    public func delete(categoryId: String) {
        categories.removeAll { $0.id == categoryId }
        assignments = assignments.filter { $0.value.categoryId != categoryId }
        save()
    }

    // MARK: filing

    /// Files a conversation. A user filing always lands and is remembered; a
    /// model filing (byUser: false) only fills where the user hasn't spoken.
    public func assign(captureId: String, to categoryId: String, byUser: Bool) {
        guard categories.contains(where: { $0.id == categoryId }) else { return }
        if !byUser, let existing = assignments[captureId], existing.byUser { return }
        assignments[captureId] = Assignment(categoryId: categoryId, byUser: byUser)
        save()
    }

    /// Removes a conversation's filing (back to uncategorized, by the user).
    public func unassign(captureId: String) {
        assignments[captureId] = Assignment(categoryId: "", byUser: true)
        save()
    }

    public func category(for captureId: String) -> ConversationCategory? {
        guard let a = assignments[captureId] else { return nil }
        return categories.first { $0.id == a.categoryId }
    }

    /// True when the model may still suggest (the user hasn't filed it).
    public func acceptsAutoSuggestion(for captureId: String) -> Bool {
        !(assignments[captureId]?.byUser ?? false)
    }

    public func captureIds(in categoryId: String, from ids: [String]) -> [String] {
        ids.filter { assignments[$0]?.categoryId == categoryId }
    }

    // MARK: persistence (tolerant: corrupt file → defaults, never a crash)

    private func load() {
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(State.self, from: data) {
            categories = state.categories
            assignments = state.assignments
        } else {
            categories = Self.defaultNames.map { ConversationCategory(id: "default-\($0.lowercased())", name: $0) }
            assignments = [:]
        }
    }

    private func save() {
        let state = State(categories: categories, assignments: assignments)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Capture-tree accessors (what the phone actually holds)

extension CaptureManager {
    /// The text search may honestly look at: the locally cached Kiln transcript
    /// or the provisional on-device transcript (both on disk). `nonisolated` so
    /// whole-list sweeps run off the main actor — it touches only the immutable
    /// baseDir and the filesystem.
    public nonisolated func searchText(for captureId: String) -> String? {
        if let cached = TranscriptCacheStore.load(captureId: captureId, baseDir: baseDir),
           !cached.transcript.isEmpty {
            return cached.transcript
        }
        return ConversationCardStore.load(captureId: captureId, baseDir: baseDir)?
            .provisionalTranscript
    }

    /// Real per-segment byte sizes (seq order) for the row's waveform thumbnail.
    /// Empty when audio has been pruned — the row then simply shows no waveform.
    public nonisolated func segmentSizes(for captureId: String) -> [Int] {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasPrefix("seg-") && $0.hasSuffix(".opus") }
            .sorted()
            .compactMap { name in
                (try? FileManager.default.attributesOfItem(
                    atPath: dir.appendingPathComponent(name).path)[.size] as? Int)
            }
    }

    /// The category store lives beside the captures it organizes.
    public nonisolated func makeCategoryStore() -> ConversationCategoryStore {
        ConversationCategoryStore(baseDir: baseDir)
    }
}

// MARK: - Waveform thumbnail

public enum WaveformThumb {
    /// Buckets real segment sizes into a 0…1 energy profile for the row
    /// thumbnail. Fewer segments than buckets → one bar per segment (honest,
    /// never interpolated). Empty input → empty profile (no fake waveform).
    public static func profile(sizes: [Int], buckets: Int) -> [Double] {
        guard !sizes.isEmpty, buckets > 0 else { return [] }
        let n = min(buckets, sizes.count)
        let per = Double(sizes.count) / Double(n)
        var out: [Double] = []
        for b in 0..<n {
            let lo = Int(Double(b) * per), hi = max(lo + 1, Int(Double(b + 1) * per))
            let slice = sizes[lo..<min(hi, sizes.count)]
            out.append(Double(slice.reduce(0, +)) / Double(slice.count))
        }
        let peak = out.max() ?? 1
        return peak > 0 ? out.map { $0 / peak } : out
    }
}
