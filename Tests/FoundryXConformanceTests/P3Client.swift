import Foundation
import Darwin

/// A client, written from the operator's side of the wire.
///
/// This deliberately speaks raw bytes rather than reusing any FoundryXKit transport.
/// The obligation is to prove what the RELAY does when a client behaves a given way,
/// and a client built out of the same types the relay's counterpart uses would agree
/// with it by construction. Here the request is written out in full, so a
/// non-conforming client is a different string rather than a mocked-out branch.
struct P3Client {
    let port: UInt16

    struct Exchange {
        /// Exactly what came back, byte for byte. The refusal comparison is on this.
        var bytes: Data
        /// Whether the connection was closed by the peer without any reply at all.
        var closedWithoutReply: Bool
        /// How long the exchange took, for the element that is about a bound.
        var elapsed: TimeInterval

        var text: String { String(decoding: bytes, as: UTF8.self) }
        var upgraded: Bool { text.hasPrefix("HTTP/1.1 101 ") }
        var refused: Bool { text.hasPrefix("HTTP/1.1 403 ") }
        var sessionToken: String? {
            for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("x-foundry-session-token:") {
                return line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        /// The challenge the relay just ISSUED, off its `GET /p3/challenge` route.
        ///
        /// MATCHED CASE-INSENSITIVELY, and that is not laziness about a constant. The
        /// relay sends this value back under `X-Foundry-Connect-Challenge` and requires
        /// it under `x-foundry-connect-challenge`: the two spellings differ, and a
        /// client that pinned either one as bytes would be pinning a fact HTTP does not
        /// carry. What IS load-bearing is the value — see `ConnectIdentity.fetchChallenge`.
        var issuedChallenge: String? {
            for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("x-foundry-connect-challenge:") {
                return line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        /// Any header that names a negotiated protocol version. Element 2 turns on
        /// whether one exists at all, so this asks the response rather than the source.
        var negotiatedVersionHeader: String? {
            for line in text.split(separator: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased()
                // MATCH ON THE HEADER NAME, AND ON A NAME THAT MEANS THIS. The first cut
                // matched any LINE containing "version", which a `Server-Version: 1` or
                // an `X-Build-Version: 1` satisfies — a relay that never negotiated
                // anything would have passed the element by shipping a build stamp. The
                // name is still read off the RESPONSE rather than pinned from the
                // relay's source, but it has to name a negotiated protocol version.
                guard (name.contains("protocol") && name.contains("version"))
                        || name == "sec-websocket-protocol" else { continue }
                return String(line)
            }
            return nil
        }
        /// The VALUE the relay echoed, not merely the fact that some header mentioned a
        /// version. A selection is proved by the value being a member of what was
        /// offered; a header whose presence is asserted and whose content is not is a
        /// decoration a constant satisfies.
        var negotiatedVersionValue: String? {
            guard let header = negotiatedVersionHeader, let colon = header.firstIndex(of: ":") else { return nil }
            return String(header[header.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Open a real TCP connection, write `request`, and read whatever comes back until
    /// the head is complete, the peer closes, or `readTimeout` elapses. Sending nothing
    /// (`request` empty) is how the auth-window element is driven.
    func exchange(request: String, readTimeout: TimeInterval = 3.0) throws -> Exchange {
        let started = Date()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw P3ClientError.io("socket() failed: \(errno)") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw P3ClientError.io("connect() to 127.0.0.1:\(port) failed: \(errno)") }

        var tv = timeval(tv_sec: Int(readTimeout), tv_usec: Int32((readTimeout - floor(readTimeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        if !request.isEmpty {
            let payload = Array(request.utf8)
            var sent = 0
            while sent < payload.count {
                let n = payload.withUnsafeBufferPointer { buf in
                    Darwin.send(fd, buf.baseAddress! + sent, payload.count - sent, 0)
                }
                guard n > 0 else { throw P3ClientError.io("send() failed: \(errno)") }
                sent += n
            }
        }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(readTimeout)
        var peerClosed = false
        while Date() < deadline {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
                if String(decoding: out, as: UTF8.self).contains("\r\n\r\n") { break }
                continue
            }
            if n == 0 { peerClosed = true; break }
            break // timeout or error: report what we have, do not spin
        }
        return Exchange(bytes: out,
                        closedWithoutReply: peerClosed && out.isEmpty,
                        elapsed: Date().timeIntervalSince(started))
    }

    /// What happened on the socket AFTER the head, which is the phase the design puts
    /// the handshake in (`03-protocols.md` P3 step 3: tenant bind and negotiation are
    /// steps 1–2, the mutual handshake is step 3, and it is post-upgrade).
    ///
    /// This exists because the pre-upgrade `exchange` above stops at `\r\n\r\n` and so
    /// cannot tell "the relay upgraded and then spoke" from "the relay upgraded and
    /// then closed". Those are the two answers the prologue element turns on.
    struct AfterUpgrade {
        var head: Exchange
        /// Every byte the relay sent after the head, within the window.
        var trailing: Data
        /// The peer closed the connection rather than continuing.
        var peerClosed: Bool
        /// How long the window actually waited, so a zero-byte result cannot be a
        /// window nobody opened.
        var windowWaited: TimeInterval
    }

    /// Write `request`, read the head, then keep listening for `window` seconds.
    /// `thenSend` (if any) is written after the head arrives, so a relay that reads a
    /// first handshake message rather than writing one is also given its chance.
    func exchangeThenListen(request: String, window: TimeInterval, thenSend: Data? = nil) throws -> AfterUpgrade {
        let started = Date()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw P3ClientError.io("socket() failed: \(errno)") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw P3ClientError.io("connect() to 127.0.0.1:\(port) failed: \(errno)") }

        func setTimeout(_ seconds: TimeInterval) {
            var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        setTimeout(3.0)

        let payload = Array(request.utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBufferPointer { buf in
                Darwin.send(fd, buf.baseAddress! + sent, payload.count - sent, 0)
            }
            guard n > 0 else { throw P3ClientError.io("send() failed: \(errno)") }
            sent += n
        }

        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var closedDuringHead = false
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 {
                out.append(contentsOf: buf[0..<n])
                if String(decoding: out, as: UTF8.self).contains("\r\n\r\n") { break }
                continue
            }
            if n == 0 { closedDuringHead = true }
            break
        }

        // SPLIT AT THE HEAD TERMINATOR, NOT AT THE READ BOUNDARY. A relay that writes
        // its `101` and its first handshake message without an intervening flush
        // delivers both in ONE segment, and attributing the whole segment to the head
        // makes a relay that DID speak after the upgrade look silent. That is not
        // hypothetical: mutation M2 (write bytes straight after the upgrade) SURVIVED
        // this drive until this split existed — the element reported `unmet` against a
        // relay that had just answered. A read boundary is the network's choice; the
        // protocol's boundary is `\r\n\r\n`.
        var trailing = Data()
        if let terminator = out.range(of: Data("\r\n\r\n".utf8)) {
            trailing = out.suffix(from: terminator.upperBound)
            out = out.prefix(upTo: terminator.upperBound)
        }
        let head = Exchange(bytes: out,
                            closedWithoutReply: closedDuringHead && out.isEmpty,
                            elapsed: Date().timeIntervalSince(started))

        // A WRITE ONTO A CLOSED PEER IS AN ANSWER, NOT AN ERROR TO SWALLOW. If the relay
        // has already closed, this send draws EPIPE (or a reset that surfaces on the
        // next read as ECONNRESET). Both mean the same thing — the peer is gone — and
        // ignoring the result made the window's verdict depend on which of `recv() == 0`
        // and `recv() < 0 (ECONNRESET)` the kernel happened to deliver first. That is a
        // FLAKY MEASUREMENT, and it was caught by a mutation run whose red named the
        // wrong cause: "the window was asked for 2.00s, waited 0.00s ... and the peer
        // did not close" against a relay that had certainly closed.
        var peerGone = false
        if let extra = thenSend, !extra.isEmpty {
            let n = extra.withUnsafeBytes { raw in Darwin.send(fd, raw.baseAddress!, raw.count, 0) }
            if n < 0 && (errno == EPIPE || errno == ECONNRESET) { peerGone = true }
        }

        // The window is a real wait. It is measured and reported, because "the relay
        // sent nothing" is only evidence if somebody actually listened.
        let windowStart = Date()
        setTimeout(window)
        var peerClosed = closedDuringHead || peerGone
        while Date().timeIntervalSince(windowStart) < window {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 { trailing.append(contentsOf: buf[0..<n]); continue }
            if n == 0 { peerClosed = true }
            // A reset is the peer being gone, reported through the other door.
            if n < 0 && errno == ECONNRESET { peerClosed = true }
            break
        }
        return AfterUpgrade(head: head, trailing: trailing, peerClosed: peerClosed,
                            windowWaited: Date().timeIntervalSince(windowStart))
    }

    // MARK: the request shapes

    /// The version this client speaks and therefore predicts the relay will select.
    ///
    /// It is one number rather than a list because the connect frame must be signed over
    /// the version the exchange is ABOUT TO produce, and negotiation happens in the same
    /// request that carries the frame — so a client offering `{1}` signs `1`, and if it
    /// offered a set it would have to predict `max(offer ∩ what the relay speaks)` before
    /// it has been told what the relay speaks. Predicting wrong is not a soft failure: the
    /// proof covers the version, so the signature simply does not verify.
    static let clientVersion: UInt16 = 1

    /// The relay's SECOND route, matched by it as a whole request line
    /// (`serve::CHALLENGE_REQUEST_LINE`). Written out in full here for the same reason every
    /// other request in this file is: the obligation is to prove what the relay does when a
    /// client sends given bytes, and a line assembled from parts is a line nobody sent.
    static let challengeRequestLine = "GET /p3/challenge HTTP/1.1"

    /// The conforming request: the relay's one route, the address, the client's pin of the
    /// community it expects to reach, its version offer — and, since foundry's auth middle
    /// landed, a connect frame that PROVES which key is on the connection.
    ///
    /// The frame is what the pin never could. `x-foundry-community-pid` is a value the
    /// client copies out of the deployment's own public bindings, so every check above it
    /// can be passed by anybody who has read one line of configuration; the proof can only
    /// be made by whoever holds the private half.
    static func conforming(host: String, community: String, identity: ConnectIdentity) throws -> String {
        try offering(String(clientVersion), host: host, community: community, identity: identity)
    }

    /// The same request with the version offer under the client's control — `nil` for
    /// a client that sends no offer header at all.
    ///
    /// Negotiation is an EXCHANGE (T10 spec §5.1: the offer rides the same pre-upgrade
    /// request that carries the host, and the relay echoes its selection in the upgrade
    /// acceptance). An exchange is only proved by driving BOTH directions, so the offer
    /// has to be a parameter rather than a constant baked into `conforming`.
    ///
    /// The connect frame is always signed over [`clientVersion`], including on the offers
    /// this client expects to be refused. That is deliberate and it is not a shortcut: a
    /// request whose offer the relay cannot meet is refused AT NEGOTIATION, which runs
    /// before the auth middle, so the frame on it is never read. Signing something else
    /// there would be inventing a second client shape for a code path nobody reaches.
    static func offering(_ offer: String?, host: String, community: String,
                         identity: ConnectIdentity) throws -> String {
        let offerLine = offer.map { "x-foundry-protocol-offer: \($0)\r\n" } ?? ""
        return try "GET /p3 HTTP/1.1\r\nHost: \(host)\r\nx-foundry-community-pid: \(community)\r\n"
            + offerLine
            + identity.frameHeaders(host: host, community: community, version: clientVersion)
            + "\r\n"
    }

    /// NON-CONFORMING FIXTURE, case 1: a client that names no community. It cannot
    /// detect a silently re-pointed address, which is exactly why the contract requires
    /// the pin. If this is admitted the feature is worthless, so it must be refused.
    ///
    /// It still carries a VALID connect frame, signed over the community it really is
    /// reaching — it is conforming in every respect except the one it is named for.
    /// Dropping the frame too would make this stimulus reach two distinct causes at once
    /// (`MissingPin` and `MissingIdentity`) and the relay refuses at the first, so the
    /// fixture would have stopped driving the cause it is named for without anything going
    /// red.
    static func namingNoCommunity(host: String, community: String, identity: ConnectIdentity) throws -> String {
        try "GET /p3 HTTP/1.1\r\nHost: \(host)\r\nx-foundry-protocol-offer: 1\r\n"
            + identity.frameHeaders(host: host, community: community, version: clientVersion)
            + "\r\n"
    }

    /// NON-CONFORMING FIXTURE, case 2: a client that asserts a community rather than
    /// one the address is bound to.
    static func namingWrongCommunity(host: String, identity: ConnectIdentity) throws -> String {
        let asserted = String(repeating: "cd", count: 32)
        return try "GET /p3 HTTP/1.1\r\nHost: \(host)\r\nx-foundry-community-pid: \(asserted)\r\n"
            + "x-foundry-protocol-offer: 1\r\n"
            + identity.frameHeaders(host: host, community: asserted, version: clientVersion)
            + "\r\n"
    }
}

/// The client half of the relay's auth middle: a key, the location it says it is
/// connecting from, and the five header lines that carry a proof of possession.
///
/// ## What is signed, and why each field is in it
///
/// `identity::connect_body` is seven canonical fields — identity, origin, community,
/// version, location, challenge, timestamp — and every one of them is load-bearing from
/// the client's side too:
///
///  * without `origin` a proof harvested at one deployment's door opens every other one;
///  * without `community` a proof made for one tenant on a shared host opens another's;
///  * `version` is the half of N1's prologue the relay can check at connect time, and it
///    is carried as its own field rather than concatenated onto the host, because the
///    canonical encoder is length-prefixed per field and hand-concatenating would
///    reintroduce the boundary ambiguity that encoder exists to remove;
///  * `location` is signed so it cannot be edited in flight — the relay is explicit that
///    it remains a CLAIM rather than a verified fact, and this client does not pretend
///    otherwise;
///  * `challenge` and `timestamp` are what stop the proof being replayable.
///
/// ## The challenge is THE RELAY'S, and this client FETCHES IT FIRST
///
/// It used to be a nonce this client picked, and the note here said so and predicted the
/// change. The change has landed (foundry main `6de3bb3c`, "a captured proof is spent once
/// for the DEPLOYMENT"): the relay draws 32 bytes of OS entropy, writes the issuance down
/// under `<deployment>/challenges/`, and hands the value back — and a proof over a value
/// the deployment did not issue is refused as `unissued-challenge`. A client-chosen value
/// is now no more admissible than a forged signature, and for the same reason: it is not
/// something the far side agreed to.
///
/// So the order of operations here is FETCH, THEN ASSEMBLE, and it cannot be the other way
/// round. [`fetchChallenge`] opens its own connection to `GET /p3/challenge`, and the
/// identity is built around the value that came back. The route sits BELOW the relay's host
/// guard and its tenancy lookup and ABOVE the client's pin, its version offer and the whole
/// auth middle (`serve.rs`, "THE CHALLENGE ROUTE ENDS HERE"), so the fetch names a host this
/// deployment binds and NOTHING else — no pin, no offer, no frame. That is why the fetch can
/// be made by a client that has not yet proved anything: holding a challenge grants nothing.
///
/// ## Why the fetch REFUSES rather than falling back
///
/// The prediction this type used to carry said "no call site changes". It was wrong, and the
/// correction is the point. A fetch can fail, and every way it can fail ends in a request
/// the relay answers with a `403` that is byte-identical to an unenrolled key, a stale
/// timestamp and a bad signature — the one refusal is correct and this target must not ask
/// for it to be weakened. A client that swallowed the failure and signed a placeholder would
/// turn a broken harness into "the relay refused", which is the single most expensive
/// misreading available in this suite. So the fetch THROWS, naming what it asked for and
/// what came back, and the request builders throw with it.
///
/// A FRESH FETCH PER REQUEST. A challenge is spent once per DEPLOYMENT — a cross-process
/// test-and-set, not a process-local map — so a value reused on a second connection is
/// refused as `spent`, and one held longer than the deployed `auth_frame_timeout_seconds` is
/// pruned and refused as `unissued`. Both are the same bytes as everything else.
struct ConnectIdentity {
    let key: Secp256k1.SigningKey
    /// The location this client says it is. A SIGNED CLAIM: the relay types it as one
    /// (`session_context::SignedLocationClaim`) because the signed device set carries no
    /// public key to resolve a location against, so nothing on the far side can verify it.
    let locationId: String

    /// Where this client goes to be ISSUED a challenge.
    ///
    /// Optional and set by the fixture once the relay is listening, because the port is not
    /// knowable until then — the relay is asked for `:0` and prints what it got. Left `nil`
    /// it is a REFUSAL naming the wiring, never a fetch against port zero: a harness that
    /// forgot to wire this would otherwise produce a `403` and read as a relay defect.
    var challengeSource: ChallengeSource?

    /// The deployment to draw challenges from: a port, and a host that deployment BINDS.
    ///
    /// The host is here rather than taken from the request being signed because the two are
    /// not the same question. A challenge is a deployment-wide value — the store is
    /// `<deployment>/challenges/`, not per-host — and the host on the fetch only decides
    /// whether the relay will issue at all. The fixtures that deliberately name an address
    /// the deployment does NOT bind still need a real challenge to carry, so they fetch
    /// against the bound host and sign over the unbound one, which is exactly the request
    /// the element means to make.
    struct ChallengeSource {
        let port: UInt16
        let host: String
    }

    var identityKeyHex: String { key.publicKeyHex }

    /// The five header lines, each already terminated — the caller appends the blank line
    /// that ends the head.
    ///
    /// A FRESH FRAME PER REQUEST, always, and now a fresh FETCH per frame. See the type's
    /// note: a challenge is spendable once for the whole deployment, so a cached frame
    /// replayed on a second connection is refused — which on the wire is the same bytes as
    /// every other refusal, and would therefore show up as an unexplained non-upgrade
    /// rather than as a bug.
    func frameHeaders(host: String, community: String, version: UInt16) throws -> String {
        let challenge = try fetchChallenge()
        let timestamp = UInt64(Date().timeIntervalSince1970)
        let body = FoundrySigning.connectBody(identityKeyHex: key.publicKeyHex,
                                              normalizedHost: host,
                                              communityPid: community,
                                              negotiatedVersion: version,
                                              locationId: locationId,
                                              challengeHex: challenge,
                                              timestamp: timestamp)
        let proof = FoundrySigning.sign(key, tag: FoundrySigning.connectTag, body: body)
        return "x-foundry-identity-key: \(key.publicKeyHex)\r\n"
            + "x-foundry-location-id: \(locationId)\r\n"
            + "x-foundry-connect-challenge: \(challenge)\r\n"
            + "x-foundry-connect-timestamp: \(timestamp)\r\n"
            + "x-foundry-connect-proof: \(proof)\r\n"
    }

    /// THE ONE PLACE A CHALLENGE IS OBTAINED — and it is obtained, never chosen.
    ///
    /// The shape is checked here as well as by the relay, and the check is 64 LOWER-CASE hex
    /// characters rather than "64 hex". That is not cosmetic. `challenge::is_challenge_shape`
    /// is the relay's traversal guard as well as its frame check, because the value becomes a
    /// path component in the spent store — so upper-case hex is a DIFFERENT challenge and
    /// draws the ordinary `403`. Checking it here means a relay that ever started issuing a
    /// value it would not accept is a named failure in this harness rather than a mute one.
    private func fetchChallenge() throws -> String {
        guard let source = challengeSource else {
            throw P3ClientError.challenge("""
            this client has no challenge source, so it cannot be issued anything to sign. The relay \
            no longer accepts a client-chosen value: the fixture must set `identity.challengeSource` \
            once the relay is listening. THIS IS THE REFUSAL — a request assembled without one would \
            be answered with the same 403 as an unenrolled key.
            """)
        }
        let reply = try P3Client(port: source.port)
            .exchange(request: "\(P3Client.challengeRequestLine)\r\nHost: \(source.host)\r\n\r\n")
        guard let issued = reply.issuedChallenge, !issued.isEmpty else {
            throw P3ClientError.challenge("""
            asked \(P3Client.challengeRequestLine) for \(source.host) on port \(source.port) and was \
            issued no challenge. The relay answered: \
            \(reply.text.isEmpty ? "<nothing at all>" : reply.text.split(separator: "\r\n").joined(separator: " | "))
            """)
        }
        let lowerHex = Set("0123456789abcdef")
        guard issued.count == 64, issued.allSatisfy({ lowerHex.contains($0) }) else {
            throw P3ClientError.challenge("""
            the relay issued \"\(issued)\", which is not the 64 LOWER-CASE hex characters it says it \
            issues (challenge::CHALLENGE_HEX_WIDTH, challenge::is_challenge_shape). Signing it would \
            produce a 403 indistinguishable from every other 403.
            """)
        }
        return issued
    }
}

enum P3ClientError: Error, CustomStringConvertible {
    case io(String)
    /// The relay would not, or did not, issue something to sign. Separate from `io` because
    /// it is a separate fact: the socket worked and the exchange did not produce a challenge.
    case challenge(String)
    var description: String {
        switch self {
        case .io(let m): return m
        case .challenge(let m): return m
        }
    }
}
