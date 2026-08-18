// DeletionRecorder — where a deletion attempt is written down.
//
// Deletion is rare, irreversible, and remote. When someone says "I deleted my
// account and it's still billing", the only way to answer is a record — and the
// obvious place to keep one, the on-device store, is EXACTLY what a deletion
// destroys. A record kept there vanishes with the thing it documents.
//
// So this ships each line straight to the relay's /diag/log (→ Cloud Logging),
// and it ships IMMEDIATELY rather than riding DoorLog's 15s batch: a successful
// "delete everywhere" erases the library and signs the person out, and a batched
// line can die in that gap. One small POST per deletion is nothing; a missing
// record of an irreversible act is not.
//
// The server ALSO audits every request fail-closed before acting, so the two
// records are independent. What this one uniquely covers is the attempts that
// never reach the server at all — an expired sign-in, a missing route, no
// network — which are invisible server-side by definition.
//
// Carries the SCOPE and the OUTCOME. Never an email, never a note's contents:
// this is a record that a deletion happened, not a copy of what was deleted.

import Foundation

public final class DeletionRecorder: @unchecked Sendable {
    public static let shared = DeletionRecorder()

    private let lock = NSLock()
    private var endpoint: URL?
    private var session: URLSession
    /// Kept for the seams, which assert what would have been shipped.
    private var emitted: [String] = []

    public init(endpoint: URL? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Point the recorder at the relay diag sink (e.g. `…/diag/log`).
    public func setEndpoint(_ url: URL?) {
        lock.lock(); endpoint = url; lock.unlock()
    }

    /// The closure handed to `AccountDeletionModel`.
    public var record: @Sendable (String, String) -> Void {
        { [weak self] event, detail in self?.emit(event, detail) }
    }

    public func emit(_ event: String, _ detail: String) {
        let line = "\(event) \(detail)"
        lock.lock()
        emitted.append(line)
        let url = endpoint
        lock.unlock()
        guard let url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["lines": [line]])
        // THE SAME CHOKE POINT `DoorLog` SHIPS THROUGH. The local record above is kept whatever
        // happens — it is what a billing dispute is answered from — and only the leg that
        // leaves the machine is withheld when this process is a test run.
        FoundryXDiagShipping.send(req, using: session)
    }

    /// Everything recorded so far, in order — the seams' read side.
    public func recorded() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return emitted
    }

    public func clear() {
        lock.lock(); emitted.removeAll(); lock.unlock()
    }
}
