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
struct ContractElement {
    let id: String
    let name: String
    /// What the client did and what came back, in one line, so a NOT-SERVED verdict
    /// carries its own evidence instead of pointing at this file.
    var observation: String = ""
    var served: Bool = false
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

    // 1 — the (normalized_host ‖ version) prologue bytes.
    static func prologue(_ c: P3Client, _ f: RelayProcessFixture) throws -> ContractElement {
        var e = ContractElement(id: "prologue-bytes", name: "the (normalized_host || version) prologue bytes")
        let prologue = f.boundHost + "p3"
        let r = try c.exchange(request: prologue + P3Client.conforming(host: f.boundHost, community: f.communityPid))
        e.served = r.upgraded
        e.observation = r.upgraded
            ? "sent \(prologue.count) prologue bytes ahead of the request and the connection upgraded"
            : "sent \(prologue.count) prologue bytes ahead of the request and the relay answered \(firstLine(r)) — it reads a request line, not a prologue"
        return e
    }

    // 2 — version negotiation as a wire exchange, not an asserted field.
    static func negotiation(_ c: P3Client, _ f: RelayProcessFixture) throws -> ContractElement {
        var e = ContractElement(id: "version-negotiation", name: "version negotiation as a wire exchange, not an asserted field")
        let offering = "GET /p3 HTTP/1.1\r\nHost: \(f.boundHost)\r\nx-foundry-community-pid: \(f.communityPid)\r\n"
            + "x-foundry-protocol-offer: 1\r\n\r\n"
        let r = try c.exchange(request: offering)
        if let header = r.negotiatedVersionHeader {
            e.served = true
            e.observation = "offered version 1 and the reply named one: \(header)"
        } else {
            e.served = false
            e.observation = "offered version 1 and the reply named none — \(headerNames(r)) — so there is no exchange, only a constant"
        }
        return e
    }

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
