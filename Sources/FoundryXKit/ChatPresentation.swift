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
    /// The DOOR answered, but it holds no kiln-session to route the turn to (503). The Mac is
    /// awake and reachable; Kiln is not running. A different, differently-fixable thing.
    public static let kilnNotRunning = "Kiln isn't running on your computer."
    /// The door answered but could not reach its own kiln-session (502).
    public static let kilnUnreachable = "Your computer couldn't reach Kiln."
    /// The DoorLog detail for an empty stream.
    public static let emptyReplyLogDetail = "stream ended with 0 events (door closed before any reply)"

    /// The calm, human sentence the thread renders. Never a code, never a
    /// domain, never the word "HTTP".
    ///
    /// The door deliberately distinguishes "I hold no kiln-session at all" (503) from "I
    /// could not reach the session" (502), for the same reason the chat LIBRARY already
    /// does (`DoorFailureMessage.make(kilnLibraryFailure:)`): a stopped Kiln and a sleeping
    /// Mac are different problems with different fixes, and "try again" is the wrong advice
    /// for both. A send is where the reader is most likely to meet them, so the send says
    /// which — the client is as honest as the contract it is handed.
    public static func calmMessage(for error: Error) -> String {
        if let de = error as? DoorError {
            switch de {
            case .transport: return unreachable
            case .http(503): return kilnNotRunning
            case .http(502): return kilnUnreachable
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
