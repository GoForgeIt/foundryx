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

// MARK: - Scan-free warm row

/// A lightweight placeholder row for the FIRST paint of the Capture list (T1 AC5):
/// captureId + title + a short date label, read from `card.json` only — NO segment scan.
/// Replaced by the real `CaptureWAL` cards the instant off-main hydration completes.
public struct ConversationRowLite: Identifiable, Sendable, Equatable {
    public let captureId: String
    public let title: String
    public let dateLabel: String
    public var id: String { captureId }

    public init(captureId: String, title: String, dateLabel: String) {
        self.captureId = captureId
        self.title = title
        self.dateLabel = dateLabel
    }
}

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
    /// Sizes come from the bulk enumeration's prefetched `.fileSizeKey` (a plain
    /// getattrlist), NEVER attributesOfItem (which does getxattr/listxattr — the
    /// extended-attribute fetch behind the bug_type-328 hangs).
    public nonisolated func segmentSizes(for captureId: String) -> [Int] {
        let dir = baseDir.appendingPathComponent(captureId, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return urls.filter { $0.lastPathComponent.hasPrefix("seg-") && $0.pathExtension == "opus" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
    }

    /// The category store lives beside the captures it organizes.
    public nonisolated func makeCategoryStore() -> ConversationCategoryStore {
        ConversationCategoryStore(baseDir: baseDir)
    }
}

// MARK: - Waveform thumbnail

public enum WaveformThumb {
    /// Buckets real segment sizes into a 0…1 energy profile for the row thumbnail.
    /// Fewer segments than buckets → one bar per segment. The real per-segment
    /// amplitude is HONEST and never interpolated: a profile with genuinely varied
    /// amplitude is returned UNCHANGED (contract holds — the seed never overwrites real
    /// data, T1 AC7).
    ///
    /// ONLY a DEGENERATE profile — ≤1 bucket, or near-constant / all-equal amplitude —
    /// falls back to a `seed`-derived varied shape, so no card renders a dead flat line
    /// (T1 AC4). Empty input still yields an empty profile (no fake waveform; the card
    /// draws no line).
    public static func profile(sizes: [Int], buckets: Int, seed: String = "") -> [Double] {
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
        let normalized = peak > 0 ? out.map { $0 / peak } : out
        // Degenerate-only fallback: a single bucket, or a profile so flat it reads as a
        // line, gets a deterministic seeded shape (same card → same waveform every time).
        return isDegenerate(normalized) ? seededProfile(seed: seed, buckets: buckets) : normalized
    }

    /// A profile is degenerate when it can't render an up/down shape: ≤1 point, or its
    /// amplitude spread is too small to be seen (near-constant / all-equal segments).
    static func isDegenerate(_ profile: [Double]) -> Bool {
        guard profile.count > 1 else { return true }
        let mn = profile.min() ?? 0, mx = profile.max() ?? 0
        return (mx - mn) < 0.15
    }

    /// A deterministic varied profile seeded by the capture id — mirrors the prototype's
    /// `y = 7 + (rand()-.5)*9` shape (baseline 0.5, ±~0.32) so the fallback looks like a
    /// real little waveform. Deterministic (FNV-1a seed → LCG) so a card's fallback never
    /// jitters between renders.
    static func seededProfile(seed: String, buckets: Int) -> [Double] {
        let n = max(2, min(buckets, 24))
        var state = fnv1a(seed.isEmpty ? "waveform" : seed)
        var out: [Double] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Double((state >> 11) & 0xFFFF_FFFF) / Double(0xFFFF_FFFF)
            let v = 0.5 + (r - 0.5) * (9.0 / 14.0)   // prototype 7 ± 4.5 on a ~14 scale
            out.append(max(0, min(1, v)))
        }
        return out
    }

    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash == 0 ? 0x0000_0100_0000_01b3 : hash
    }
}
