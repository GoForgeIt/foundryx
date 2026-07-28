// CaptureLibrary — "does this person have any voice notes yet?"
//
// The on-disk shape of a note is a directory under the captures root named for its
// capture id (`CaptureWAL.init` → `root/<captureId>`), and capture ids are prefixed by
// the source that made them (`omi-…`, `mic-…`). Two places already needed to answer
// "is the library empty" and each open-coded that prefix rule — `OnboardingPrefs
// .migrateIfPriorUse` to decide whether an established install should be re-onboarded,
// and now the onboarding ending, which must know whether the first voice note actually
// landed. A rule spelled twice drifts once, so it lives here.
//
// Deliberately a directory scan and nothing more: no CaptureManager, no WAL parsing, no
// I/O beyond one `contentsOfDirectory`. It answers presence, not content.

import Foundation

public enum CaptureLibrary {
    /// Capture-id prefixes, one per source that can open a note.
    static let sourcePrefixes = ["omi-", "mic-"]

    /// Is `name` the directory name of a voice note?
    public static func isNoteDirectory(_ name: String) -> Bool {
        sourcePrefixes.contains { name.hasPrefix($0) }
    }

    /// How many voice notes are on disk under `baseDir`. Zero for a missing or
    /// unreadable directory — an unreadable library is empty as far as the UI is
    /// concerned, and this is never the authority for deletion.
    public static func noteCount(baseDir: URL) -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? []
        return entries.filter(isNoteDirectory).count
    }

    /// Nothing captured yet — the state the onboarding ending exists to get the user out
    /// of, and the state the home screen's "make your first voice note" copy speaks to.
    public static func isEmpty(baseDir: URL) -> Bool { noteCount(baseDir: baseDir) == 0 }
}
