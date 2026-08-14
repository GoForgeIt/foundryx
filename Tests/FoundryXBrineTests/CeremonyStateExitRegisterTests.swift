import XCTest
import Foundation
@testable import FoundryXKit

/// THE STATE-EXIT GATE — can a person standing in this state REACH the thing that would help?
///
/// ## The defect class
///
/// `ProductionReachabilityRegisterTests` asks whether shipping code ever CALLS a capability.
/// This asks the question one level in: whether a capability that IS called can be reached from
/// the state a user actually lands in. Six instances, all the same shape — implemented, tested,
/// reachable from one state, orphaned from another:
///
///   1. `.handshakeUnanswered` — the recorder holds a key ours does not match, so this firmware
///      goes SILENT — had NO exits at all, while `.setupUnavailable` had three.
///   2. `PocketFactoryResetPresentation`, a whole written screen with cost-first copy and
///      provenance, was reachable ONLY from the consent screen — which means "Solleva holds no
///      key", and is therefore the one state a recorder with a WRONG stored key can never reach.
///   3. `PocketSessionKeyEntry` hung off the same state for the same reason.
///   4. The Pocket sync modules had tests and zero `App/` callers.
///   5. Chat on a cell had no MCP tools.
///   6. `.didNotFinish` — what a recorder that REFUSED the key Solleva holds lands on — carried
///      "Try again" as its first, PRIMARY button, and that title fell through `ceremonyAction`'s
///      `default` arm and closed the entire connect sheet. The screen's own body reads "Try again
///      before you close this."
///
/// ## Why this can't be a heuristic
///
/// "Every screen offers every action" is wrong and, here, dangerous. A one-tap "forget this
/// recorder" on a screen produced by SILENCE is a one-tap brick: this firmware has no reset
/// opcode, no unpair and no key-read opcode, and custody may hold the only copy of the key in
/// existence. `.acceptedNotDurable` (§3.7) must have exactly ONE action and no dismissal, because
/// closing it loses a recorder forever. The exits a state needs are a judgement, and judgements
/// live in a table somebody has to edit.
///
/// ## What is measured rather than read
///
/// The kit's action arrays are read as RUNTIME VALUES (this suite links `FoundryXKit`). The
/// routing table is read as the TEXT of `App/DeviceScreen.swift`, which `swift test` cannot
/// compile — the same technique `DeviceCompositionRootGateTests` and the reachability register
/// already use. Nothing in the JSON is trusted: a coordinated edit that changes an action AND
/// the register's copy of it still reds, because the exit KINDS each state requires are
/// recomputed from what the routing table does with those titles.
final class CeremonyStateExitRegisterTests: XCTestCase {

    // MARK: - The register, as declared

    private struct NonButtonExit: Decodable {
        let file: String
        let anchor: String
        let why: String
    }

    private struct DirectPresenter: Decodable {
        let file: String
        let anchor: String
    }

    private struct ActionRoute: Decodable {
        let id: String
        /// The source spelling `ceremonyAction` matches on. A literal on one side and a constant
        /// on the other is a routing bug that compiles.
        let constant: String
        /// The method the arm calls. Wired, not merely present.
        let handler: String
        let kind: String
        let why: String
    }

    private struct State: Decodable {
        let id: String
        /// The `PocketOnboardingView.Screen` case.
        let screen: String
        let presentation: String
        let reachable: Bool
        /// How many `ceremonyScreen = .<screen>` assignments `App/DeviceScreen.swift` carries.
        /// EQUALITY: a landing site that appears or vanishes is a diff somebody makes.
        let landingSites: Int
        let declaredActions: [String]
        let requiredExits: [String]
        let forbiddenExits: [String]?
        let nonButtonExit: NonButtonExit?
        let presentedDirectlyBy: DirectPresenter?
        let producibleByTheShippedFlow: Bool?
        let why: String

        enum CodingKeys: String, CodingKey {
            case id, screen, presentation, reachable, why
            case landingSites = "landing_sites"
            case declaredActions = "declared_actions"
            case requiredExits = "required_exits"
            case forbiddenExits = "forbidden_exits"
            case nonButtonExit = "non_button_exit"
            case presentedDirectlyBy = "presented_directly_by"
            case producibleByTheShippedFlow = "producible_by_the_shipped_flow"
        }
    }

    private struct ScreenEnum: Decodable {
        let file: String
        let openAnchor: String
        enum CodingKeys: String, CodingKey { case file; case openAnchor = "open_anchor" }
    }

    private struct RoutingTable: Decodable {
        let file: String
        let openAnchor: String
        let closeAnchor: String
        let landingPattern: String
        let routingIsScreenIndependent: Bool
        enum CodingKeys: String, CodingKey {
            case file
            case openAnchor = "open_anchor"
            case closeAnchor = "close_anchor"
            case landingPattern = "landing_pattern"
            case routingIsScreenIndependent = "routing_is_screen_independent"
        }
    }

    private struct Register: Decodable {
        let screenEnum: ScreenEnum
        let routingTable: RoutingTable
        let exitKinds: [String]
        let actionRoutes: [ActionRoute]
        let forbiddenActionWords: [String]
        let custodyScreenExemptFromForbiddenWords: String
        let states: [State]
        let minimumStates: Int
        let minimumReachableStates: Int
        let minimumActionRoutes: Int

        enum CodingKeys: String, CodingKey {
            case states
            case screenEnum = "screen_enum"
            case routingTable = "routing_table"
            case exitKinds = "exit_kinds"
            case actionRoutes = "action_routes"
            case forbiddenActionWords = "forbidden_action_words"
            case custodyScreenExemptFromForbiddenWords = "custody_screen_exempt_from_forbidden_words"
            case minimumStates = "minimum_states"
            case minimumReachableStates = "minimum_reachable_states"
            case minimumActionRoutes = "minimum_action_routes"
        }
    }

    private static let registerPath = "Tests/FoundryXBrineTests/registers/ceremony-state-exits.json"

    private static func loadRegister() throws -> Register {
        let url = AppSourceTree.repoRoot.appendingPathComponent(registerPath)
        return try JSONDecoder().decode(Register.self, from: try Data(contentsOf: url))
    }

    private static func code(at relativePath: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(relativePath)
        return AppSourceTree.code(of: try String(contentsOf: url, encoding: .utf8))
    }

    /// The file with COMMENTS stripped and string literals INTACT — what a check about the words
    /// on a button needs, since the words are string literals.
    private static func text(at relativePath: String) throws -> String {
        let url = AppSourceTree.repoRoot.appendingPathComponent(relativePath)
        return AppSourceTree.withoutComments(of: try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - The kit's real values

    /// THE ACTIONS A SCREEN ACTUALLY DRAWS, AS VALUES. Not a copy of them, and not a scan of the
    /// source that declares them: this suite links `FoundryXKit`, so it can ask the shipped
    /// constant. Everything else in this file is text because `App/` cannot be compiled here;
    /// this half does not have to be, and a value beats a lexer wherever one is available.
    ///
    /// It is a `switch` on the register's `presentation` id ON PURPOSE. A dictionary built by
    /// reflection would silently return `[]` for a presentation somebody renamed, and `[]`
    /// compared against `[]` is a pass. An unknown id here is a compile-visible hole and a named
    /// failure at runtime.
    private static func actions(ofPresentation id: String) -> [String]? {
        switch id {
        case "PocketSetupPresentation.setup":              return PocketSetupPresentation.setup.actions
        case "PocketSetupPresentation.didNotFinish":       return PocketSetupPresentation.didNotFinish.actions
        case "PocketSetupPresentation.acceptedNotDurable": return PocketSetupPresentation.acceptedNotDurable.actions
        case "PocketSetupPresentation.ready":              return PocketSetupPresentation.ready.actions
        case "PocketSetupPresentation.keepBothApps":       return PocketSetupPresentation.keepBothApps.actions
        case "PocketSetupPresentation.setupUnavailable":   return PocketSetupPresentation.setupUnavailable.actions
        case "PocketSetupPresentation.keyNotKept":         return PocketSetupPresentation.keyNotKept.actions
        case "PocketSetupPresentation.custodyUnreadable":  return PocketSetupPresentation.custodyUnreadable.actions
        case "PocketSetupPresentation.handshakeUnanswered": return PocketSetupPresentation.handshakeUnanswered.actions
        case "PocketMintConsentPresentation":              return PocketMintConsentPresentation.actions
        case "PocketMintRefusedPresentation":              return PocketMintRefusedPresentation.actions
        case "PocketMintNotVerifiedPresentation":          return PocketMintNotVerifiedPresentation.actions
        case "PocketFactoryResetPresentation":             return PocketFactoryResetPresentation.actions
        // `keyCustody` and `enterExistingKey` are drawn by their own bodies rather than from an
        // `actions` array; only `doneAction` reaches `action(title)`. The field has no routed
        // button at all — its exit is the submit closure, declared as `non_button_exit`.
        case "PocketKeyCustodyPresentation":               return [PocketKeyCustodyPresentation.doneAction]
        case "PocketSessionKeyEntryPresentation":          return []
        case "PocketDeviceEducation":                      return []
        default:                                           return nil
        }
    }

    /// The VALUE of a constant the routing table matches on. Same reasoning as above, and the
    /// same refusal to guess: an unknown spelling is a named failure, never an empty string.
    private static func value(ofConstant id: String) -> String? {
        switch id {
        case "PocketSessionKeyEntryPresentation.entryAction":  return PocketSessionKeyEntryPresentation.entryAction
        case "PocketMintConsentPresentation.confirmAction":    return PocketMintConsentPresentation.confirmAction
        case "PocketMintConsentPresentation.resetAction":      return PocketMintConsentPresentation.resetAction
        case "PocketSetupPresentation.retrySecureStorageAction": return PocketSetupPresentation.retrySecureStorageAction
        case "PocketSetupPresentation.retryAction":            return PocketSetupPresentation.retryAction
        case "PocketFactoryResetPresentation.retryAction":     return PocketFactoryResetPresentation.retryAction
        case "PocketMintNotVerifiedPresentation.retryAction":  return PocketMintNotVerifiedPresentation.retryAction
        case "PocketKeyCustodyPresentation.entryAction":       return PocketKeyCustodyPresentation.entryAction
        default:                                               return nil
        }
    }

    // MARK: - Population, before contents

    /// NON-VACUOUS FIRST, and the population is checked against the ENUM rather than against a
    /// floor alone. A ceremony screen that exists and is not declared here is a screen whose
    /// exits nobody stated — which is the entire defect, arriving by omission.
    func testEveryCeremonyScreenHasARowAndEveryRowIsAScreen() throws {
        let register = try Self.loadRegister()
        XCTAssertGreaterThanOrEqual(register.states.count, register.minimumStates,
            "the register declares \(register.states.count) states and its own floor is "
                + "\(register.minimumStates). A register that shrank is a gate that stopped asking.")
        XCTAssertGreaterThanOrEqual(register.actionRoutes.count, register.minimumActionRoutes,
                                    "the routing table's declared rows shrank")
        XCTAssertGreaterThanOrEqual(
            register.states.filter(\.reachable).count, register.minimumReachableStates,
            "fewer reachable states than the floor — either screens were removed or somebody "
                + "demoted a row rather than fixing it")

        var seen = Set<String>()
        for id in register.states.map(\.id) {
            XCTAssertTrue(seen.insert(id).inserted, "duplicate state id: \(id)")
        }

        let declared = Set(register.states.map(\.screen))
        let actual = try Self.screenEnumCases(register)
        XCTAssertFalse(actual.isEmpty,
                       "no cases parsed out of \(register.screenEnum.file)'s `Screen` enum — the "
                           + "anchor `\(register.screenEnum.openAnchor)` no longer opens it, and "
                           + "every population claim below is computed from nothing")
        XCTAssertEqual(declared, actual, """
        the ceremony screens and the register's rows disagree.
          screens with no row: \(actual.subtracting(declared).sorted())
          rows with no screen: \(declared.subtracting(actual).sorted())
        A screen with no row is a state whose exits nobody stated — and a row with no screen is a \
        guarantee about something that no longer exists.
        """)
        print("STATE-EXITS: \(register.states.count) states "
              + "(\(register.states.filter(\.reachable).count) reachable), "
              + "\(register.actionRoutes.count) routed actions")
    }

    /// The `Screen` enum's cases, from the view's own source. `swift test` cannot compile `App/`,
    /// so this is a lexer over the declared anchor's brace-balanced body.
    private static func screenEnumCases(_ register: Register) throws -> Set<String> {
        let source = try code(at: register.screenEnum.file)
        guard let open = source.range(of: register.screenEnum.openAnchor) else { return [] }
        var depth = 0
        var body = ""
        for character in source[open.lowerBound...] {
            if character == "{" { depth += 1; if depth == 1 { continue } }
            if character == "}" { depth -= 1; if depth == 0 { break } }
            if depth >= 1 { body.append(character) }
        }
        var cases = Set<String>()
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            for name in trimmed.dropFirst("case ".count).components(separatedBy: ",") {
                let cleaned = name.trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { cases.insert(cleaned) }
            }
        }
        return cases
    }

    // MARK: - The routing table, as text

    /// `ceremonyAction`'s body, sliced between the two declared anchors. Both are asserted to
    /// exist: an anchor that stopped matching would make every routing claim below vacuous, and a
    /// vacuous routing check reads exactly like a working one.
    private static func routingBody(_ register: Register) throws -> String {
        let source = try code(at: register.routingTable.file)
        guard let open = source.range(of: register.routingTable.openAnchor) else {
            XCTFail("""
            \(register.routingTable.file) no longer contains `\(register.routingTable.openAnchor)`. \
            The routing table is the object every ceremony button is dispatched through; if it was \
            renamed, nothing below is measuring anything.
            """)
            return ""
        }
        guard let close = source.range(of: register.routingTable.closeAnchor,
                                       range: open.upperBound..<source.endIndex) else {
            XCTFail("\(register.routingTable.file): the routing table's close anchor "
                    + "`\(register.routingTable.closeAnchor)` no longer follows it")
            return ""
        }
        return String(source[open.upperBound..<close.lowerBound])
    }

    /// EVERY DECLARED ROUTE IS STILL A ROUTE — the constant is matched in a `case` position and
    /// the arm still calls the handler the register names.
    func testEveryDeclaredActionRouteIsStillWired() throws {
        let register = try Self.loadRegister()
        let body = try Self.routingBody(register)
        guard !body.isEmpty else { return }

        for route in register.actionRoutes {
            XCTAssertNotNil(Self.value(ofConstant: route.constant), """
            \(route.id) names the constant `\(route.constant)`, which this checker cannot resolve \
            to a value. Add it to `value(ofConstant:)` — a route whose title is unknown cannot be \
            matched against any screen's actions, and an unmatched route silently satisfies nothing.
            """)
            XCTAssertTrue(body.contains(route.constant), """
            THE ROUTE IS GONE — \(route.id) ("\(route.kind)") declares that \
            `\(register.routingTable.file)`'s ceremony routing matches `\(route.constant)`, and the \
            switch no longer names it. Every title it carried now falls to `default`, which CLOSES \
            THE CONNECT SHEET. That is the shape of the shipped defect: a screen whose primary \
            button dismisses the flow while its own copy asks you not to.
            """)
            XCTAssertTrue(body.contains(route.handler), """
            \(route.id) declares that its arm calls `\(route.handler)` and the routing table no \
            longer does. A `case` with no call is a button that returns `.handled` and does nothing \
            — worse than one that closes the sheet, because nothing at all happens.
            """)
        }
    }

    /// THE INVARIANT THAT KILLS THE SUB-CLASS. `ceremonyAction` used to read
    /// `case PocketSetupPresentation.retryAction where ceremonyScreen == .keyNotKept || …`, so
    /// "Try again" was a retry on three screens and a sheet-dismissal on the fourth. That
    /// allowlist is a table that must be edited every time a screen gains an action, and the edit
    /// that was missed is defect (6). Routing by title alone cannot have that hole.
    func testTheRoutingTableIsNotConditionalOnWhichScreenIsUp() throws {
        let register = try Self.loadRegister()
        guard register.routingTable.routingIsScreenIndependent else { return }
        let body = try Self.routingBody(register)
        guard !body.isEmpty else { return }
        XCTAssertFalse(body.contains(" where "), """
        \(register.routingTable.file)'s ceremony routing has grown a `where` clause. The register \
        declares this switch screen-INDEPENDENT, and the reason is recorded: the allowlist that \
        used to guard the retry row is exactly why `.didNotFinish` — the screen a REFUSED key \
        lands on — had a primary "Try again" button that closed the whole connect sheet.

        If a screen-conditional route is genuinely needed, set `routing_is_screen_independent` to \
        false and say in the register which state is excluded and why. That is a diff somebody has \
        to defend; a `where` clause added quietly is not.
        """)
    }

    // MARK: - Landing sites: is the state reachable at all?

    /// BOTH DIRECTIONS. A state declared reachable with no landing site is a DEAD ROW; a state
    /// declared unreachable that acquires one is a promotion the register has not absorbed —
    /// and `.keepBothApps` is sitting there with two dead buttons waiting for exactly that.
    func testEveryStateIsLandedOnAsOftenAsItDeclares() throws {
        let register = try Self.loadRegister()
        let source = try Self.code(at: register.routingTable.file)
        for state in register.states {
            let needle = register.routingTable.landingPattern + state.screen
            // Bounded on the right so `.keyNotKept` cannot be counted by `.keyNotKeptSomething`.
            let count = Self.occurrences(of: needle, in: source, notFollowedByIdentifierCharacter: true)
            XCTAssertEqual(count, state.landingSites, """
            \(state.id) — screen `.\(state.screen)`
              declared landing sites: \(state.landingSites)
              found in \(register.routingTable.file): \(count)
            \(state.landingSites > count
                ? "A route into this state was renamed, moved or deleted. If a user can no longer land here, say so; if they can, restore it."
                : "A NEW ROUTE LANDS PEOPLE HERE and nobody stated what they can do from it. Declare the site, and check `required_exits` still holds for the way they now arrive.")
            """)
            if state.reachable {
                let hasDirectPresenter = state.presentedDirectlyBy != nil
                XCTAssertTrue(count > 0 || hasDirectPresenter, """
                \(state.id) is declared REACHABLE and nothing in \(register.routingTable.file) \
                lands on `.\(state.screen)`, nor does it declare a direct presenter. A reachable \
                row with no way in is a guarantee about a state that does not occur.
                """)
            } else {
                XCTAssertEqual(count, 0, """
                \(state.id) is declared UNREACHABLE and \(register.routingTable.file) now lands on \
                `.\(state.screen)` \(count) time(s). Somebody wired it up. Its actions are \
                \(state.declaredActions) — check every one of them is routed, state the exits this \
                state needs, and promote the row. \(state.why)
                """)
            }
            if let presenter = state.presentedDirectlyBy {
                let presenting = try Self.code(at: presenter.file)
                XCTAssertTrue(presenting.contains(presenter.anchor), """
                \(state.id) declares it is presented directly by `\(presenter.anchor)` in \
                \(presenter.file), and that call site is gone. This state has no `ceremonyScreen` \
                landing site by construction, so the direct presenter is the ONLY thing that makes \
                it reachable at all.
                """)
            }
            if let exit = state.nonButtonExit {
                let holding = try Self.text(at: exit.file)
                XCTAssertTrue(holding.contains(exit.anchor), """
                \(state.id) declares a non-button exit anchored at `\(exit.anchor)` in \
                \(exit.file), and it is gone. \(exit.why)
                """)
            }
        }
    }

    private static func occurrences(of needle: String, in haystack: String,
                                    notFollowedByIdentifierCharacter: Bool) -> Int {
        var count = 0
        var cursor = haystack.startIndex
        while let found = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            cursor = found.upperBound
            if notFollowedByIdentifierCharacter, found.upperBound < haystack.endIndex {
                let next = haystack[found.upperBound]
                if next.isLetter || next.isNumber || next == "_" { continue }
            }
            count += 1
        }
        return count
    }

    // MARK: - The actions, as EQUALITY against the shipped values

    /// The declared actions must be exactly what the kit draws. Containment would let an exit be
    /// deleted without a diff — which is precisely how a screen loses its way out.
    func testEveryStateDrawsExactlyTheActionsItDeclares() throws {
        let register = try Self.loadRegister()
        for state in register.states {
            guard let actual = Self.actions(ofPresentation: state.presentation) else {
                XCTFail("""
                \(state.id) names the presentation `\(state.presentation)`, which this checker \
                cannot resolve. Add it to `actions(ofPresentation:)`. A presentation that resolves \
                to nothing would compare `[]` against `[]` and pass while proving nothing.
                """)
                continue
            }
            XCTAssertEqual(actual, state.declaredActions, """
            \(state.id) — screen `.\(state.screen)`, drawn from `\(state.presentation)`
              declared: \(state.declaredActions)
              actual:   \(actual)
            An action that vanished is an EXIT THAT VANISHED, and the state may now be a trap. An \
            action that appeared is a button nobody has said what it does. \(state.why)
            """)
        }
    }

    // MARK: - THE GATE: can this state reach what it needs?

    /// Every required exit must be REACHABLE from the state — the title is on the screen AND the
    /// routing table does something with it. This is the assertion the six shipped defects would
    /// each have failed.
    func testEveryStateCanReachTheExitsItNeeds() throws {
        let register = try Self.loadRegister()
        let body = try Self.routingBody(register)
        guard !body.isEmpty else { return }

        var byTitle: [String: ActionRoute] = [:]
        for route in register.actionRoutes {
            guard let title = Self.value(ofConstant: route.constant) else { continue }
            byTitle[title] = route
        }
        for kind in register.states.flatMap({ $0.requiredExits + ($0.forbiddenExits ?? []) }) {
            XCTAssertTrue(register.exitKinds.contains(kind),
                          "a state requires or forbids the exit kind `\(kind)`, which the register "
                              + "does not declare in `exit_kinds`")
        }

        var stranded: [String] = []
        for state in register.states {
            guard let actual = Self.actions(ofPresentation: state.presentation) else { continue }

            // What this state can actually DO, recomputed: the titles it draws, resolved through
            // the routing table. A title with no route falls to `default` and closes the sheet,
            // which is never an exit that changes the person's situation.
            var reachable: [String: String] = [:]   // kind -> title
            var unrouted: [String] = []
            for title in actual {
                if let route = byTitle[title], body.contains(route.constant) {
                    reachable[route.kind] = title
                } else {
                    unrouted.append(title)
                }
            }

            for kind in state.requiredExits {
                XCTAssertNotNil(reachable[kind], """
                STRANDED — \(state.id) ("\(state.screen)") cannot reach `\(kind)`.
                  it draws:      \(actual)
                  it can reach:  \(reachable.keys.sorted())
                  unrouted:      \(unrouted)  (these fall to `default` and CLOSE THE CONNECT SHEET)
                  it needs:      \(state.requiredExits)

                \(state.why)

                This is the defect class this register exists to close: the capability is written, \
                is tested, and is reachable from some OTHER state. Wire the action onto this \
                screen's `actions` array and give the title a `case` in the routing table — or, if \
                this exit genuinely does not belong here, take it out of `required_exits` and say \
                why in the row.
                """)
            }
            for kind in state.forbiddenExits ?? [] {
                XCTAssertNil(reachable[kind], """
                \(state.id) offers `\(kind)` ("\(reachable[kind] ?? "")"), and the register forbids \
                it from this state. \(state.why)
                """)
            }
            // A REACHABLE STATE WITH NOTHING BUT DISMISSALS IS A TRAP, whatever it declares. This
            // is the floor under the per-state judgement above, so a row cannot be made green by
            // emptying its own `required_exits`.
            if state.reachable && reachable.isEmpty && state.nonButtonExit == nil {
                stranded.append("\(state.id) (.\(state.screen)) draws \(actual) — every one of "
                                + "them closes the sheet")
            }
        }
        XCTAssertEqual(stranded, [], """
        REACHABLE STATE(S) WITH NO EXIT THAT CHANGES ANYTHING:
        \(stranded.map { "  " + $0 }.joined(separator: "\n"))
        A person who lands here can only close the flow and land here again. That is the trap, and \
        emptying a row's `required_exits` does not make it one.
        """)
    }

    /// THE DESTRUCTIVE BUTTON THIS FLOW MAY NOT GROW.
    ///
    /// `forget` is first because it is the button somebody will reach for on `.handshakeUnanswered`
    /// — the screen produced by a recorder saying NOTHING. Silence is not evidence the key is
    /// wrong, this firmware has no reset opcode and no key-read opcode, and on a recorder Solleva
    /// minted for, custody may hold the only copy of the key in existence. A one-tap forget there
    /// is a one-tap brick. The honest escape is to REPLACE the key (`PocketSecretStore.save`
    /// overwrites) or to start the recorder over, and both are already exits.
    func testNoCeremonyStateOffersToDestroyOrDisplayACredential() throws {
        let register = try Self.loadRegister()
        for state in register.states {
            guard state.screen != register.custodyScreenExemptFromForbiddenWords,
                  let actual = Self.actions(ofPresentation: state.presentation) else { continue }
            for title in actual {
                for word in register.forbiddenActionWords {
                    XCTAssertFalse(title.lowercased().contains(word), """
                    \(state.id) offers "\(title)". `\(word)` is forbidden on every ceremony screen \
                    but `\(register.custodyScreenExemptFromForbiddenWords)`.
                    A `forget` is unrecoverable on hardware with no reset and no key-read opcode; \
                    a reveal/copy/export on a setup screen is the security property \
                    `features/pocket-existing-key-entry.feature` forbids outright.
                    """)
                }
            }
        }
    }

    /// The honest roster, printed. `.acceptedNotDurable` is REACHED by four App call sites and is
    /// NOT PRODUCIBLE by the shipped flow (custody runs before the `APP&SK&` write), and those are
    /// different facts — a checker that collapsed them would be the disease it was built to cure.
    func testTheRosterIsPrintedIncludingWhatNoScenarioCanStage() throws {
        let register = try Self.loadRegister()
        let unreachable = register.states.filter { !$0.reachable }
        let unproducible = register.states.filter { $0.producibleByTheShippedFlow == false }
        print("STATE-EXITS: \(register.states.count - unreachable.count) reachable, "
              + "\(unreachable.count) not routed, \(unproducible.count) reached-but-not-producible")
        for state in unreachable {
            print("STATE-EXITS: NOT ROUTED — \(state.id) (.\(state.screen)): "
                  + "\(state.declaredActions)")
        }
        for state in unproducible {
            print("STATE-EXITS: NOT PRODUCIBLE — \(state.id) (.\(state.screen)) has "
                  + "\(state.landingSites) App landing site(s) and no scenario can stage it")
        }
        XCTAssertFalse(register.states.isEmpty)
    }
}
