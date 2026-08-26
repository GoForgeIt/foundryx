import Foundation

/// Reaching the captures the launch bound leaves on disk.
///
/// `CaptureManager.maxCapturesToLoad` (300) is a real constraint, not an oversight: hydrating
/// every folder at launch enumerated tens of thousands of directories on the main thread,
/// overran the iOS launch watchdog and got the app SIGKILL'd. The bound STAYS. What was missing
/// is a way PAST it — AC8's first draft accepted "reachable-or-stated", and the review rightly
/// called that authorized truncation-by-disclaimer. A sentence is not a way in.
public enum LocalCapturePaging {

    public struct Page: Equatable, Sendable {
        public let ids: [String]
        /// The cursor for the page after this one, or nil at exhaustion.
        public let nextAfter: String?
    }

    /// The next `limit` capture ids after `after`, in the SAME newest-first order the launch
    /// hydration uses — so a page boundary means the same thing on both paths.
    ///
    /// `after` is an ID, not an index: an index shifts when a capture is added or discarded
    /// between pages, which silently skips or repeats a row. An id that is no longer present
    /// yields NOTHING rather than restarting at the top, because a restart re-serves page one
    /// forever and reads as progress.
    public static func page(names: [String], after: String?, limit: Int) -> Page {
        let ordered = names.sorted(by: >)
        var start = 0
        if let after {
            guard let idx = ordered.firstIndex(of: after) else {
                return Page(ids: [], nextAfter: nil)
            }
            start = ordered.index(after: idx)
        }
        guard start < ordered.count, limit > 0 else { return Page(ids: [], nextAfter: nil) }
        let end = min(start + limit, ordered.count)
        let ids = Array(ordered[start..<end])
        // A cursor ONLY while rows remain. Emitting one on the last page makes the walk
        // non-terminating, which hangs a caller instead of ending it.
        let next = end < ordered.count ? ids.last : nil
        return Page(ids: ids, nextAfter: next)
    }
}
