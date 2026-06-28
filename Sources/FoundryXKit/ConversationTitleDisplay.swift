// ConversationTitleDisplay — list-rendering disambiguation for GENERIC / duplicate
// conversation titles (track 20260628T1609). Near-silent captures often transcribe to
// the same throwaway phrase ("Thank you", "Okay", "Bye"), so the list shows several
// cards that LOOK like the same conversation. This appends the conversation's start
// time to a generic title so two different short captures read distinctly.
//
// It changes ONLY the list rendering — the stored Kiln title (card.json / the door) is
// never mutated. Pure + unit-tested. A specific, content-bearing title is returned
// unchanged.

import Foundation

public enum ConversationTitleDisplay {
    /// Low-information phrases a near-silent capture commonly transcribes to. Matched
    /// case-insensitively after trimming punctuation/whitespace.
    static let genericTitles: Set<String> = [
        "thank you", "thanks", "thank you.", "okay", "ok", "yeah", "yes", "no",
        "bye", "goodbye", "hello", "hi", "hey", "uh", "um", "mm", "mhm",
        "you", "the", "processing", "processing…", "processing...", "untitled",
    ]

    /// A title is "generic" when it carries little distinguishing information: it is a
    /// known throwaway phrase, OR it is very short (≤ 2 words and ≤ 12 characters).
    public static func isGeneric(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let normalized = trimmed
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:…"))
        if genericTitles.contains(normalized) { return true }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        return words.count <= 2 && trimmed.count <= 12
    }

    /// The title to RENDER in the list: a generic title gets the start time appended so
    /// duplicates read distinctly ("Thank you · 8:25 PM"); a specific title is returned
    /// unchanged. `timeString` formats the conversation's start (device-local).
    public static func display(title: String, start: Date,
                               timeString: (Date) -> String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGeneric(trimmed) else { return trimmed }
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        return "\(base) · \(timeString(start))"
    }
}
