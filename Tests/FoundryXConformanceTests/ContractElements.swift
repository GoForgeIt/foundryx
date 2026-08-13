import Foundation

/// The five elements of T10's published P3 client contract (T25 spec §2.3), each
/// DRIVEN against the running relay and each verdict COMPUTED from what came back.
///
/// The reason this file exists rather than a table of expectations: an element marked
/// served because a constant with the right name exists in the relay's source is an
/// element nobody has met. `foundry-relay`'s `serve.rs` declares
/// `NEGOTIATED_VERSION: &str = "p3"` and `config.rs` declares
/// `KEY_AUTH_FRAME_TIMEOUT`, and a source-reading check would count both as served.
/// Every verdict below is the answer a socket gave.
/// The verdict on ONE question inside an element.
///
/// `notReached` exists so that a question the run could not ask is recorded as
/// unasked rather than as answered. An element whose second stage is unreachable
/// because its first stage failed would otherwise report a bare `false` that reads
/// as "driven and refuted".
enum PartVerdict: String {
    case met
    case unmet
    case notReached = "not-reached"
}

struct ContractElement {
    let id: String
    let name: String
    /// What the client did and what came back, in one line, so a NOT-SERVED verdict
    /// carries its own evidence instead of pointing at this file.
    var observation: String = ""
    var served: Bool = false
    /// The individual questions this element's verdict is made of, in the order they
    /// were asked.
    ///
    /// A single `served` bool hides which half moved. Two of this target's elements
    /// are conjunctions, and a conjunction that reports only its result cannot tell a
    /// mutation that broke one conjunct from one that broke the other — worse, a
    /// mutation that flips a conjunct while the AND stays false is INVISIBLE. The
    /// register declares these part by part and the run compares them part by part.
    var parts: [(name: String, verdict: PartVerdict)] = []

    var partMap: [String: String] { Dictionary(uniqueKeysWithValues: parts.map { ($0.name, $0.verdict.rawValue) }) }
}

enum ContractElementDriver {

    static let declaredIds = [
        "prologue-bytes",
        "version-negotiation",
        "host-binding-before-upgrade",
        "auth-timeout",
        "generic-rejections",
    ]

    /// Drive all five. Order is irrelevant; each opens its own connection.
    static func driveAll(client: P3Client, fixture: RelayProcessFixture) throws -> [ContractElement] {
        [
            try prologue(client, fixture),
            try negotiation(client, fixture),
            try hostBinding(client, fixture),
            try authTimeout(client, fixture),
            try genericRejections(client, fixture).element,
        ]
    }

    // 1 — the (normalized_host ‖ negotiated_version) prologue.
    //
    // RE-SPECIFIED 2026-08-13. The previous drive sent `(boundHost ‖ "p3")` ahead of
    // the request head and called the relay's `403` a failure to serve. That was wrong
    // about the wire, and the design says so three times over:
    //
    //   * `design/03-protocols.md` P3 orders the protocol `1. TCP/TLS + tenant bind
    //     BEFORE the upgrade → 2. version negotiation → 3. mutual handshake (Noise-XX)
    //     with prologue = (normalized_host ‖ negotiated_version)`, and the per-connection
    //     state machine is `tcp-open → tenant-bound → version-negotiated → handshaking`.
    //     The prologue belongs to step 3. Sending it at step 1 is two states early.
    //   * T10 spec §5.1 RESOLVES the connect wire: the offer rides "the same pre-upgrade
    //     request that carries the host", and the relay "echoes the negotiated version in
    //     the upgrade acceptance, and binds it into the prologue". The bytes at connect
    //     are an HTTP head and a `101`. A relay that accepted a prologue-shaped prefix
    //     ahead of that head would be speaking a protocol no document designs.
    //   * A NOISE PROLOGUE IS NEVER TRANSMITTED, and this repository's own primitive
    //     says so: `Sources/FoundryXKit/NoiseXX.swift:209-211` takes `prologue: Data` and
    //     `mixHash`es it. It is an input to the transcript hash that both peers must
    //     already hold. That is exactly the property 03-protocols claims for it — "a
    //     handshake transcript completed for community A's host cannot be replayed
    //     against community B, because the prologue disagrees" — and a prologue put on
    //     the wire would give no such property, because a replaying peer would simply
    //     send the same bytes.
    //
    // So the element is driven as the design's three questions instead of one invented
    // one. It is still NOT SERVED, and now for a reason that is true.
    static func prologue(_ c: P3Client, _ f: RelayProcessFixture) throws -> ContractElement {
        var e = ContractElement(id: "prologue-bytes", name: "the (normalized_host || negotiated_version) prologue, bound into the handshake")

        // PART 1 — the connect wire must REFUSE a prologue, in every encoding, because
        // accepting one is the invented protocol. Driven with both plausible encodings
        // of `‖` (decimal-ASCII and u16 big-endian) so the verdict does not rest on a
        // choice no document makes.
        let asciiPrologue = Data((f.boundHost + "1").utf8)
        var wirePrologue = Data(f.boundHost.utf8); wirePrologue.append(contentsOf: [0x00, 0x01])
        let head = P3Client.conforming(host: f.boundHost, community: f.communityPid)
        var refusedEncodings = 0
        var acceptedEncodings: [String] = []
        for (label, bytes) in [("decimal-ascii", asciiPrologue), ("u16-big-endian", wirePrologue)] {
            let prefix = String(decoding: bytes, as: UTF8.self)
            let r = try c.exchange(request: prefix + head)
            if r.refused && !r.upgraded { refusedEncodings += 1 } else { acceptedEncodings.append(label) }
        }
        let wireRefusesPrologue: PartVerdict = (refusedEncodings == 2) ? .met : .unmet

        // PART 2 — the handshake the prologue is bound INTO, at the phase the design
        // puts it: after the upgrade. Nothing is asserted about its contents; the only
        // question is whether an exchange happens at all, because a prologue binds a
        // transcript and a connection with no transcript has nothing to bind.
        let window = Double(f.authTimeoutSeconds)
        let after = try c.exchangeThenListen(request: head, window: window, thenSend: wirePrologue)
        let handshakeExists: PartVerdict = (after.head.upgraded && !after.trailing.isEmpty) ? .met : .unmet
        // A PROBE THAT DID NOT HAPPEN MUST REFUSE, NEVER RECORD A VALUE. "The relay sent
        // nothing" is evidence only if the listening really occurred: either the peer
        // closed (a definite answer, whenever it came) or the window really elapsed. A
        // silent zero from a window nobody opened would be an `unmet` nobody measured.
        if handshakeExists == .unmet && !after.peerClosed && after.windowWaited < window * 0.9 {
            throw ConformanceStepError("""
            prologue-bytes part 2 could not be measured: the post-upgrade window was asked for \
            \(String(format: "%.2f", window))s, waited \(String(format: "%.2f", after.windowWaited))s, \
            read 0 bytes and the peer did not close. That is an unmeasured window, not an absent handshake.
            """)
        }

        // PART 3 — the binding itself: a transcript completed against one bound host
        // must not complete against another. Unreachable while part 2 is unmet, and
        // recorded as UNASKED rather than as a `false` that would read as refuted.
        let bindingDifferential: PartVerdict = (handshakeExists == .met) ? .unmet : .notReached

        e.parts = [("connect-wire-refuses-a-prologue", wireRefusesPrologue),
                   ("post-upgrade-handshake-exists", handshakeExists),
                   ("prologue-binding-differential", bindingDifferential)]
        e.served = e.parts.allSatisfy { $0.verdict == .met }

        let part1 = wireRefusesPrologue == .met
            ? "the connect wire refused a prologue in both encodings (2 of 2), which is what the design requires of it"
            : "the connect wire ACCEPTED a prologue-shaped prefix in \(acceptedEncodings.joined(separator: ", ")) — that is a protocol no document designs"
        let part2 = handshakeExists == .met
            ? "after the upgrade the relay sent \(after.trailing.count) byte(s) within \(String(format: "%.2f", after.windowWaited))s"
            : after.peerClosed
                ? "after \(firstLine(after.head)) the relay closed the connection \(String(format: "%.2f", after.windowWaited))s later without sending one handshake byte, and without reading the prologue it was offered"
                : "after \(firstLine(after.head)) the relay held the connection open for the whole \(String(format: "%.2f", after.windowWaited))s window and sent nothing"
        e.observation = "\(part1); \(part2), so there is no step-3 handshake for a prologue to be mixed into and the binding differential was NOT REACHED"
        return e
    }

    // 2 — version negotiation as a wire exchange, not an asserted field.
    //
    // STRENGTHENED 2026-08-13. The previous drive made ONE offer (`1`), accepted any
    // reply header whose name merely CONTAINED "version", and asserted nothing about
    // what happens to an offer the relay cannot meet. A relay that stamped a constant
    // header on every reply passed it — which is the exact defect the element exists to
    // detect. An exchange is `offer → selection → echo`, and only the refusal direction
    // proves the relay READ the offer rather than decorated the reply.
    static func negotiation(_ c: P3Client, _ f: RelayProcessFixture) throws -> ContractElement {
        var e = ContractElement(id: "version-negotiation", name: "version negotiation as a wire exchange, not an asserted field")

        // (a) an offer the relay can meet is selected and ECHOED BY VALUE. The echoed
        // version has to be a member of what was offered; a constant is not a selection.
        let offered = "1"
        let accepted = try c.exchange(request: P3Client.offering(offered, host: f.boundHost, community: f.communityPid))
        let echoed = accepted.negotiatedVersionValue
        let selectionEchoed: PartVerdict = (accepted.upgraded && echoed == offered) ? .met : .unmet

        // (b) a WELL-FORMED offer with no common member is refused pre-upgrade. `65535`
        // is a legal version by T10 §2.3's pinned type and range, so this reaches the
        // relay's selection rather than its parser — the case the differential calls
        // bad-version, and the one that is unreachable while negotiation is a constant.
        let disjoint = try c.exchange(request: P3Client.offering("65535", host: f.boundHost, community: f.communityPid))
        let noCommonRefused: PartVerdict = (disjoint.refused && !disjoint.upgraded) ? .met : .unmet

        // (c) a client that offers nothing has not negotiated, and is refused. Without
        // this the relay could serve every version-less client a default, which is the
        // downgrade the exchange exists to prevent.
        let silent = try c.exchange(request: P3Client.offering(nil, host: f.boundHost, community: f.communityPid))
        let absentRefused: PartVerdict = (silent.refused && !silent.upgraded) ? .met : .unmet

        e.parts = [("offer-selected-and-echoed-by-value", selectionEchoed),
                   ("no-common-version-refused-pre-upgrade", noCommonRefused),
                   ("absent-offer-refused-pre-upgrade", absentRefused)]
        e.served = e.parts.allSatisfy { $0.verdict == .met }
        e.observation = "offered \(offered) and the reply named "
            + (echoed.map { "\(ContractElementDriver.echoHeaderName): \($0)" } ?? "no version at all (\(headerNames(accepted)))")
            + "; a legal offer of 65535 the relay does not speak answered \(firstLine(disjoint))"
            + "; an absent offer answered \(firstLine(silent))"
        return e
    }

    /// The header name the run reports the echo under, taken from the reply rather than
    /// from the relay's source.
    static let echoHeaderName = "X-Foundry-Protocol-Version"

    // 3 — host-bound tenancy established before the socket upgrades.
    static func hostBinding(_ c: P3Client, _ f: RelayProcessFixture) throws -> ContractElement {
        var e = ContractElement(id: "host-binding-before-upgrade", name: "host-bound tenancy established before the socket upgrades")
        let bound = try c.exchange(request: P3Client.conforming(host: f.boundHost, community: f.communityPid))
        let unbound = try c.exchange(request: P3Client.conforming(host: "nobody.example", community: f.communityPid))
        e.served = bound.upgraded && unbound.refused && !unbound.upgraded
        e.observation = "the bound address answered \(firstLine(bound)); an address the deployment does not bind answered \(firstLine(unbound)) and never upgraded"
        return e
    }

    // 4 — the bounded AUTH_TIMEOUT, client-observable.
    //
    // Driven by SAYING NOTHING. A relay that bounds its auth window closes or refuses
    // a silent client within the number it was deployed with. One that merely reads
    // the number leaves the connection open, and the client cannot tell the bound
    // exists — which is what "client-observable" means and why this is not a check
    // that the configuration key parses.
    static func authTimeout(_ c: P3Client, _ f: RelayProcessFixture) throws -> ContractElement {
        var e = ContractElement(id: "auth-timeout", name: "the bounded AUTH_TIMEOUT, client-observable")
        let bound = Double(f.authTimeoutSeconds)
        let slack = 2.0
        let r = try c.exchange(request: "", readTimeout: bound + slack)
        let answered = r.closedWithoutReply || !r.bytes.isEmpty
        // The window matters in BOTH directions. A relay that answers instantly is not
        // demonstrating a bound — it is refusing for some other reason, and counting
        // that as "the AUTH_TIMEOUT is client-observable" would make this element pass
        // against a relay that had never heard of the number. So the observed wait has
        // to TRACK the number the relay was deployed with.
        let tracksTheBound = r.elapsed >= bound * 0.5 && r.elapsed <= bound + slack
        e.served = answered && tracksTheBound
        e.observation = String(
            format: "said nothing; the relay %@ after %.2fs against a deployed bound of %ds",
            answered ? (r.closedWithoutReply ? "closed the connection" : "answered") : "held the connection open",
            r.elapsed, f.authTimeoutSeconds)
        return e
    }

    // 5 — byte-identical generic rejections.
    struct RejectionRun { var element: ContractElement; var causesExercised: Int; var identical: Bool }

    static func genericRejections(_ c: P3Client, _ f: RelayProcessFixture) throws -> RejectionRun {
        var e = ContractElement(id: "generic-rejections", name: "byte-identical generic rejections")
        // Distinct causes, each reachable from OUTSIDE the relay. In-process the relay
        // counts these separately; on the wire they must be one answer.
        let causes: [(String, String)] = [
            ("no community named", P3Client.namingNoCommunity(host: f.boundHost)),
            ("a community the address is not bound to", P3Client.namingWrongCommunity(host: f.boundHost)),
            ("an address the deployment does not bind", P3Client.conforming(host: "nobody.example", community: f.communityPid)),
            ("an empty address", "GET /p3 HTTP/1.1\r\nHost: \r\nx-foundry-community-pid: \(f.communityPid)\r\nx-foundry-protocol-offer: 1\r\n\r\n"),
            ("an address of nothing but spaces", "GET /p3 HTTP/1.1\r\nHost:    \r\nx-foundry-community-pid: \(f.communityPid)\r\nx-foundry-protocol-offer: 1\r\n\r\n"),
            ("a route this relay does not serve", "GET /nope HTTP/1.1\r\nHost: \(f.boundHost)\r\nx-foundry-community-pid: \(f.communityPid)\r\nx-foundry-protocol-offer: 1\r\n\r\n"),
            // The two version causes. Added 2026-08-13: D7's differential names
            // wrong-tenant / unknown-host / BAD-VERSION / timeout, and bad-version was
            // unreachable for as long as negotiation was a constant. It is reachable
            // now, and these are its two shapes — an offer that cannot be READ and an
            // offer that reads cleanly and shares no member. They are distinct causes
            // in the relay's own enum (MalformedOffer, NoCommonVersion) and must be
            // indistinguishable here, which is the whole claim.
            ("an offer that is not a version at all", P3Client.offering("not-a-version", host: f.boundHost, community: f.communityPid)),
            ("a legal version the relay does not speak", P3Client.offering("65535", host: f.boundHost, community: f.communityPid)),
        ]
        var replies: [(String, Data)] = []
        for (why, request) in causes {
            replies.append((why, try c.exchange(request: request).bytes))
        }
        let distinct = Set(replies.map { $0.1 })
        e.served = distinct.count == 1 && replies.count >= 2 && replies.allSatisfy {
            String(decoding: $0.1, as: UTF8.self).hasPrefix("HTTP/1.1 403 ")
        }
        e.observation = e.served
            ? "\(replies.count) distinct causes exercised, \(distinct.count) distinct reply on the wire"
            : "\(replies.count) distinct causes exercised produced \(distinct.count) distinct replies: " +
              replies.map { "\($0.0) -> \(String(decoding: $0.1, as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? "<nothing>")" }.joined(separator: "; ")
        return RejectionRun(element: e, causesExercised: replies.count, identical: distinct.count == 1)
    }

    // MARK: reporting helpers

    private static func firstLine(_ r: P3Client.Exchange) -> String {
        r.text.split(separator: "\r\n").first.map(String.init) ?? "<no reply at all>"
    }

    private static func headerNames(_ r: P3Client.Exchange) -> String {
        let names = r.text.split(separator: "\r\n").dropFirst().compactMap { line -> String? in
            guard let i = line.firstIndex(of: ":") else { return nil }
            return String(line[..<i])
        }
        return names.isEmpty ? "the reply carried no headers" : "the reply's headers were [\(names.joined(separator: ", "))]"
    }
}
