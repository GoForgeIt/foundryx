import Foundation

/// EVERY REQUEST THIS PHONE MAKES ACROSS THE DOOR SEAM, recorded as it is made.
///
/// ## Why this exists
///
/// The door already keeps a log of what ARRIVES — `FoundryX gateway: GET /foundryx/... →
/// route`. That log is the only artifact that ever caught the defects of 2026-08-26: the
/// conversations route reached the Mac zero times for hours, and the absence of a line was
/// the entire evidence. Nothing on the PHONE recorded what it had sent, so the two ends of
/// one seam could not be compared, and no test could assert on either.
///
/// ⚠ THE GHERKIN SUITE COULD NOT HAVE CAUGHT EITHER DEFECT, and this is why. Every scenario
/// describes what a PERSON sees or what a COMPONENT computes. Not one asserts that a request
/// crossed a seam. Measured: `grep -il 'the door receives|a request reaches' Features/*` →
/// no matches. A suite blind to the wire cannot notice a request that was never sent.
///
/// This is the phone's half of that record. It is deliberately always-on, exactly like the
/// door's: a seam observable only under test is a seam whose production behaviour nobody
/// can check, and the bug that motivated this was invisible precisely in production.
public enum DoorSeam {

    /// WHICH TRANSPORT carried the request.
    ///
    /// ⚠ THE LEG IS THE POINT, not decoration. `conversationPage` shipped with only a
    /// `direct` leg while every working route had a `relay` one, so on a phone reaching the
    /// Mac through the tunnel the request was addressed somewhere that is not the door and
    /// could never be. Recording only "a request happened" would have looked identical.
    public enum Leg: String, Sendable, Equatable {
        case relay
        case direct
    }

    public struct Crossing: Sendable, Equatable {
        public let method: String
        /// Path only — never the query, which carries a bearer-adjacent cursor and a search
        /// term. A seam record is evidence, not a transcript of the owner's content.
        public let path: String
        public let leg: Leg
        public init(method: String, path: String, leg: Leg) {
            self.method = method
            self.path = path
            self.leg = leg
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var crossings: [Crossing] = []
    /// Bounded so an always-on recorder cannot grow without limit in a long session.
    private static let bound = 200

    public static func record(method: String, path: String, leg: Leg) {
        // The query is dropped HERE rather than at each call site, so a new route cannot
        // forget and leak one into the record.
        let bare = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        lock.withLock {
            crossings.append(Crossing(method: method, path: bare, leg: leg))
            if crossings.count > bound { crossings.removeFirst(crossings.count - bound) }
        }
    }

    public static var recorded: [Crossing] { lock.withLock { crossings } }

    public static func reset() { lock.withLock { crossings = [] } }

    /// Did a request for this path cross the seam, and on which leg?
    ///
    /// Returns `nil` when the path never crossed — which is the answer the conversations
    /// defect would have given for hours, and the answer no test was asking for.
    public static func legFor(path: String) -> Leg? {
        lock.withLock { crossings.last(where: { $0.path == path })?.leg }
    }
}
