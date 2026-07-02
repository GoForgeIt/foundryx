// SpeakerSeedFormatter — turns a captured conversation into a ready-to-send CHAT SEED
// (the "Ask about this" prompt). Pure + synchronous so the recall-chip path can build
// a seed off the door's `CaptureContent` (or a cached transcript, or just a title) with
// no side effects. Thin client: it only reshapes text already on disk / already returned
// by the door — it never analyses or summarises.
//
// The shape mirrors CaptureScreen's existing "Ask in chat" seed so a recall from the
// chat empty state reads identically to a recall from a conversation:
//
//   About my conversation “<title>” (<timeRange>):
//
//   Nick: let's move the dentist appointment
//   Speaker 2: Tuesday works
//   …
//   What are the key takeaways and any action items?
//
// When the capture carries diarized segments we render speaker turns via
// `SpeakerTranscript.displayLabel(for:)`; otherwise we fall back to a flat transcript
// prefix. Either body is capped at ~2000 chars, trimmed at a clean turn / word boundary.

import Foundation

public enum SpeakerSeedFormatter {
    /// Cap the transcript body carried into the seed (matches CaptureScreen's prefix).
    public static let maxBodyChars = 2000

    /// The closing ask — identical to CaptureScreen's "Ask in chat" seed.
    static let tail = "What are the key takeaways and any action items?"

    /// Build a seed from the door's full capture content — prefers the speaker-diarized
    /// transcript (labelled turns), falling back to the flat transcript prefix, then a
    /// title-only seed when there's no usable text.
    public static func seed(from content: CaptureContent, title: String, timeRange: String) -> String {
        let diarized = content.diarized
        if diarized.hasSegments {
            let body = speakerBody(diarized, limit: maxBodyChars)
            if !body.isEmpty { return assemble(title: title, timeRange: timeRange, body: body) }
        }
        return seed(title: title, timeRange: timeRange, transcript: content.transcript)
    }

    /// Build a seed from a FLAT transcript (the cached-transcript fallback). Empty text
    /// degrades to a title-only seed.
    public static func seed(title: String, timeRange: String, transcript: String) -> String {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return titleOnlySeed(title: title, timeRange: timeRange) }
        return assemble(title: title, timeRange: timeRange, body: clip(t, to: maxBodyChars))
    }

    /// The last-resort seed: the conversation's title/time and the ask, no transcript —
    /// so the user can still open a chat about it (the door has the context server-side).
    public static func titleOnlySeed(title: String, timeRange: String) -> String {
        header(title: title, timeRange: timeRange) + "\n\n" + tail
    }

    // MARK: - Assembly

    private static func assemble(title: String, timeRange: String, body: String) -> String {
        header(title: title, timeRange: timeRange) + "\n\n" + body + "\n\n" + tail
    }

    /// "About my conversation “<title>” (<timeRange>):" — the time range is omitted
    /// cleanly when unknown; a blank title degrades to a plain "conversation".
    private static func header(title: String, timeRange: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.isEmpty ? "conversation" : name
        let range = timeRange.trimmingCharacters(in: .whitespacesAndNewlines)
        if range.isEmpty { return "About my conversation “\(label)”:" }
        return "About my conversation “\(label)” (\(range)):"
    }

    /// Render diarized turns as "Speaker: text" lines, stopping at a clean turn boundary
    /// before the body would exceed `limit`. A single opening turn longer than the whole
    /// budget is clipped mid-turn as a last resort so the seed is never empty.
    private static func speakerBody(_ transcript: SpeakerTranscript, limit: Int) -> String {
        var lines: [String] = []
        var count = 0
        for turn in transcript.turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let line = "\(transcript.displayLabel(for: turn.slot)): \(text)"
            if lines.isEmpty, line.count > limit {
                lines.append(clip(line, to: limit))
                break
            }
            if count + line.count + 1 > limit, !lines.isEmpty { break }   // stop at the turn boundary
            lines.append(line)
            count += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// Clip to `limit` chars, backing up to the last word/line break so a word isn't
    /// sliced in half, and appending an ellipsis. Short strings pass through untouched.
    private static func clip(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        let end = s.index(s.startIndex, offsetBy: limit)
        var cut = String(s[..<end])
        if let lastBreak = cut.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            cut = String(cut[..<lastBreak])
        }
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
