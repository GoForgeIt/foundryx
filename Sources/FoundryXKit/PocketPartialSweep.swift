// PocketPartialSweep.swift — THE WRECKAGE A KILLED TRANSFER LEAVES, REAPED AT LAUNCH.
//
// `20260821T0153_the_drain_survives_termination` P2.3.
//
// `PocketBringOver` writes arriving bytes to a `<timestamp>.mp3.partial` sibling and takes the
// real name only after re-reading and comparing a digest (`PocketBringOver.swift:87-88, 146`).
// That design is good and this file does not change it: **partial bytes are never mistaken for a
// recording.** What is missing is a reaper. `abandon()` is in-process only, so a kill mid-write
// leaves the `.partial` on disk forever and nothing at launch removes it. Slow, unbounded growth
// of files nobody will ever read.
//
// THE SPEC'S FIRST DRAFT GOT THIS WRONG AND THE REVIEW CAUGHT IT. It said: sweep a `.partial`
// with no in-flight transfer, keep one that IS in flight. But **after process death no writer and
// no task survive** — a `.partial` cannot "belong to an in-flight transfer" across a launch, and
// only a stale durable marker could claim otherwise. A sweep honouring that marker would preserve
// the orphan FOREVER while passing its own criterion.
//
// SO THE DISTINCTION IS PROVENANCE, NOT A FLAG. A `.partial` that existed before this process
// created a writer for it is wreckage; one whose writer this process created is live. That is
// knowable without persisting anything, which is the point — the previous version needed a
// durable claim that could itself be stale, and this one needs nothing but the current run's own
// memory of what it opened.
//
// AND IT IS CORRECT TO DELETE THEM, not merely safe: there is no offset resume in this protocol
// (`PocketTransferJob.swift:17,20`), so a retry restarts at byte zero and the old bytes are dead
// weight either way. `PocketBringOver.swift:150-151` already removes an existing partial when a
// fresh transfer begins, so the sweep is doing at launch what the next transfer would have done
// eventually — for files whose next transfer may never come.

import Foundation

/// What a sweep did, as a value rather than a count. A reaper that reports only "3" cannot be
/// audited by an operator asking WHICH files it took.
public struct PocketPartialSweepReport: Sendable, Equatable {
    /// Orphans removed. Named, so a log records what was destroyed.
    public let swept: [String]
    /// Partials left because this process owns their writer.
    public let keptLive: [String]
    /// Files that could not be removed, with the reason. **Not silently dropped** — a sweep that
    /// cannot delete is a sweep whose next run finds the same files, and hiding that turns
    /// unbounded growth into a mystery.
    public let failed: [String]

    public var isEmpty: Bool { swept.isEmpty && keptLive.isEmpty && failed.isEmpty }
}

public enum PocketPartialSweep {

    /// The extension the writer uses. One literal, shared, so the sweep and the writer cannot
    /// disagree about what wreckage looks like.
    public static let partialExtension = "partial"

    /// Reap the wreckage under `root`.
    ///
    /// - Parameter liveWriterPaths: absolute paths of `.partial` files THIS PROCESS has open.
    ///   Empty at launch, which is when this runs — the parameter exists so a sweep triggered
    ///   later, while a drain is running, cannot delete the file being written right now.
    @discardableResult
    public static func sweep(under root: URL,
                             liveWriterPaths: Set<String> = []) -> PocketPartialSweepReport {
        let fm = FileManager.default
        // PATHS ARE COMPARED RESOLVED, AND THIS IS NOT TIDINESS. `/var` is a symlink to
        // `/private/var` on this platform, so a caller holding one spelling and an enumerator
        // yielding the other never match — and a non-match here means the sweep DELETES THE FILE
        // A TRANSFER IS WRITING RIGHT NOW. Found by the scenario for exactly that, which is why
        // it is a scenario and not a comment.
        let live = Set(liveWriterPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else {
            return PocketPartialSweepReport(swept: [], keptLive: [], failed: [])
        }

        var swept: [String] = []
        var keptLive: [String] = []
        var failed: [String] = []

        for case let url as URL in walker where url.pathExtension == partialExtension {
            // THE PROVENANCE QUESTION, AND IT IS THE ONLY ONE ASKED. Not "is there a marker
            // saying this is in flight" — a marker survives the process that wrote it and the
            // work it described does not.
            if live.contains(url.resolvingSymlinksInPath().path) {
                keptLive.append(url.lastPathComponent)
                continue
            }
            do {
                try fm.removeItem(at: url)
                swept.append(url.lastPathComponent)
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return PocketPartialSweepReport(swept: swept, keptLive: keptLive, failed: failed)
    }
}
