// ChatPresentation — pure copy + failure presentation for the chat surface
// (track 20260714T1800 §7, fullflow2 "chat" scene). The consumer thread never
// renders engineering telemetry: a failed send reads as calm human copy, and
// the technical detail (HTTP codes, NSError domains, transport messages) goes
// to the DoorLog only. App/ChatScreen.swift renders these; the logic lives
// here so the brine step-defs drive the real presentation.

import Foundation

/// User-facing chat copy, in one place — testable and tweakable without
/// hunting through view code.
public enum ChatCopy {
    /// The composer's invitation (fullflow2 `renderChat`, :2372).
    public static let composerPlaceholder = "Ask FoundryX"
}

/// Calm presentation of a failed send. The thread shows one of two human
/// sentences; the engineering truth is preserved for the DoorLog.
public enum ChatSendFailure {
    /// Transport-level failure — the phone couldn't reach the desktop at all.
    public static let unreachable = "Your computer couldn't be reached."
    /// The send reached out but didn't complete (rejected, errored, empty).
    public static let tryAgain = "That didn't go through — try again."
    /// A stream that closed before any reply — same calm invitation to retry.
    public static var emptyReply: String { tryAgain }
    /// The DoorLog detail for an empty stream.
    public static let emptyReplyLogDetail = "stream ended with 0 events (door closed before any reply)"

    /// The calm, human sentence the thread renders. Never a code, never a
    /// domain, never the word "HTTP".
    public static func calmMessage(for error: Error) -> String {
        if let de = error as? DoorError {
            switch de {
            case .transport: return unreachable
            case .unauthorized, .http: return tryAgain
            }
        }
        if (error as NSError).domain == NSURLErrorDomain { return unreachable }
        return tryAgain
    }

    /// The engineering detail — DoorLog only, never the thread.
    public static func logDetail(for error: Error) -> String {
        if let de = error as? DoorError {
            switch de {
            case .unauthorized: return "401 unauthorized (bad token)"
            case .http(let code): return "HTTP \(code)"
            case .transport(let msg): return msg
            }
        }
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }
}
