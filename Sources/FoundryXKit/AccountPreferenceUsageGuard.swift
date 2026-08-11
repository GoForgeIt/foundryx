import Foundation

public struct AccountPreferenceSourceFile: Sendable, Equatable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

public struct AccountPreferenceUsageViolation: Sendable, Equatable {
    public let path: String
    public let line: Int
    public let keyOrUse: String
    public let reason: String
    public let operationFingerprint: String?
    public let ownership: String?

    public init(
        path: String,
        line: Int,
        keyOrUse: String,
        reason: String,
        operationFingerprint: String? = nil,
        ownership: String? = nil
    ) {
        self.path = path
        self.line = line
        self.keyOrUse = keyOrUse
        self.reason = reason
        self.operationFingerprint = operationFingerprint
        self.ownership = ownership
    }
}

public enum AccountPreferenceUsageGuardError: Error, Equatable {
    case missingRequiredRoot(String)
    case emptyRequiredRoot(String)
}

/// A usage-based preference classifier. It inspects only calls on known
/// persistence receivers, rather than treating every FoundryX-looking string as
/// persisted state.
public enum AccountPreferenceUsageGuard {
    public static let phoneOwnedKeys: Set<String> = [
        "foundryx.omi.peripheral-id",
        "foundryx.omi.peripheral-name",
        "foundryx.omi.last-connected",
        "foundryx.omi.central",
        "foundryx.battery.monitored.uuid",
        "foundryx.battery.monitored.name",
        "foundryx.capture.source",
        "foundryx.capture.sources.added",
        "foundryx.action-button.choice",
        "foundryx.diag.perfOverlay",
        "foundryx.auth.signed-in",
        "foundryx.capture-account-activation.v2",
        "foundryx.capture-account-scope",
        "foundryx.capture.widget-snapshot",
        "foundryx.capture.widget-snapshot.active-owner",
        // Answers "did THIS INSTALL's container survive?", which is a property of
        // the phone and not of any account. It must never be account-scoped: a
        // scoped marker would be absent for the next account and make an ordinary
        // sign-in look like a reinstall. It must also survive account deletion —
        // the container is still there, so the next launch is not a fresh install.
        "foundryx.install.marker.v1",
    ]

    public static let accountInfrastructureKeys: Set<String> = [
        "foundryx.cell.url",
        "foundryx.cell.authMode",
        "foundryx.door.url",
    ]

    public static let accountInfrastructureKeychainServices: Set<String> = [
        "com.goforgeit.foundryx.cell",
        "com.goforgeit.foundryx.door",
    ]

    private static let requiredRoots = [
        "Sources/FoundryXKit",
        "App",
        "Widget",
    ]

    private static let defaultsMethods = [
        "object", "string", "bool", "double", "data", "dictionary",
        "array", "integer", "float", "url", "stringArray", "set",
        "setValue", "removeObject", "removePersistentDomain",
    ]

    private static let expectedAccountKeys: Set<String> = [
        "foundryx.onboarding.completed",
        "foundryx.onboarding.persona",
        "foundryx.welcome.seen",
        "foundryx.welcome.letStraightIn",
        "foundryx.ambient.enabled",
        "foundryx.ambient.agentName",
        "foundryx.ambient.grading",
        "foundryx.ambient.othersInline",
        "foundryx.vault.checkoutAttempt.id",
        "foundryx.vault.checkoutAttempt.plan",
        "foundryx.brain.choice",
        "foundryx.waitlist.joined",
        "foundryx.capture.silence-gap-seconds",
        "foundryx.capture.omi-desired-state",
        "foundryx.capture.sources.enabled-overrides",
        "foundryx.models.cache.v1",
        "foundryx.account.signup-posted",
    ]

    public static func scanRepository(
        at repositoryRoot: URL,
        catalog: [AccountPreferenceCatalogEntry] = AccountPreferenceCatalog.entries
    ) throws -> [AccountPreferenceUsageViolation] {
        var sources: [AccountPreferenceSourceFile] = []
        for relativeRoot in requiredRoots {
            let root = repositoryRoot.appendingPathComponent(
                relativeRoot, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw AccountPreferenceUsageGuardError
                    .missingRequiredRoot(relativeRoot)
            }
            let files = FileManager.default
                .enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.path < $1.path } ?? []
            guard !files.isEmpty else {
                throw AccountPreferenceUsageGuardError
                    .emptyRequiredRoot(relativeRoot)
            }
            sources += try files.map { file in
                let relative = file.path
                    .replacingOccurrences(
                        of: repositoryRoot.path + "/", with: "")
                return AccountPreferenceSourceFile(
                    path: relative,
                    text: try String(contentsOf: file, encoding: .utf8))
            }
        }
        return scan(sources: sources, catalog: catalog)
    }

    public static func scan(
        sources: [AccountPreferenceSourceFile],
        catalog: [AccountPreferenceCatalogEntry] = AccountPreferenceCatalog.entries
    ) -> [AccountPreferenceUsageViolation] {
        let catalogProblems = validateCatalog(catalog)
        guard catalogProblems.isEmpty else { return catalogProblems }
        guard !sources.isEmpty else {
            return [AccountPreferenceUsageViolation(
                path: "<sources>",
                line: 0,
                keyOrUse: "<configuration>",
                reason: "preference source scan is empty")]
        }

        let entries = Dictionary(
            uniqueKeysWithValues: catalog.map { ($0.canonicalKey, $0) })
        return sources
            .sorted { $0.path < $1.path }
            .flatMap { scan($0, entries: entries) }
            .sorted {
                ($0.path, $0.line, $0.keyOrUse)
                    < ($1.path, $1.line, $1.keyOrUse)
            }
    }

    private static func validateCatalog(
        _ catalog: [AccountPreferenceCatalogEntry]
    ) -> [AccountPreferenceUsageViolation] {
        guard !catalog.isEmpty else {
            return [configurationViolation("account preference catalog is empty")]
        }
        let keys = catalog.map(\.canonicalKey)
        guard Set(keys).count == keys.count else {
            return [configurationViolation("account preference catalog has duplicate keys")]
        }
        guard catalog.allSatisfy({ $0.classification == .account }) else {
            return [configurationViolation(
                "account preference catalog contains a misclassified key")]
        }
        guard let activation = catalog.first?.activationState,
              catalog.allSatisfy({ $0.activationState == activation }) else {
            return [configurationViolation(
                "account preference catalog activation must flip atomically")]
        }
        let vault = catalog.filter { $0.atomicGroup == .vaultCheckout }
        guard Set(vault.map(\.canonicalKey)) == [
            "foundryx.vault.checkoutAttempt.id",
            "foundryx.vault.checkoutAttempt.plan",
        ] else {
            return [configurationViolation(
                "vault checkout atomic registration is incomplete")]
        }
        guard catalog.count == 17,
              Set(keys) == expectedAccountKeys else {
            return [configurationViolation(
                "account preference catalog is not the independent exact 17-key set")]
        }
        return []
    }

    private static func configurationViolation(
        _ reason: String
    ) -> AccountPreferenceUsageViolation {
        AccountPreferenceUsageViolation(
            path: "<catalog>",
            line: 0,
            keyOrUse: "<configuration>",
            reason: reason)
    }

    private struct Scope {
        let kind: String
        let name: String
        let start: Int
        let end: Int
    }

    private struct ResolvedKey {
        let key: String?
        let use: String
        let scoped: Bool
        let dynamic: Bool
    }

    private struct DefaultsAliases {
        var trusted: Set<String>
        var mutable: Set<String>
    }

    private enum DefaultsReceiver {
        case no
        case trusted
        case mutable
    }

    private static func scan(
        _ source: AccountPreferenceSourceFile,
        entries: [String: AccountPreferenceCatalogEntry]
    ) -> [AccountPreferenceUsageViolation] {
        let original = source.text
        let masked = maskNonCode(original)
        let aliases = defaultsAliases(in: original, masked: masked)
        let scopes = declarationScopes(in: masked)
        let methodPattern = "\\.\\s*(" +
            defaultsMethods.joined(separator: "|") + ")\\s*\\("
        let matches = regexMatches(methodPattern, in: masked)
        var violations: [AccountPreferenceUsageViolation] = []

        for match in matches {
            let dot = match.range.location
            let receiverKind = defaultsReceiver(
                before: dot, masked: masked, aliases: aliases)
            guard receiverKind != .no else { continue }
            let method = substring(
                masked,
                range: match.range(at: 1))
            guard let open = masked.utf16Offset(
                after: match.range.location + match.range.length - 1),
                  let close = matchingParen(
                    in: masked, openUTF16Offset: open)
            else { continue }
            let callStart = callStartOffset(before: dot, in: masked)
            let line = lineNumber(atUTF16Offset: callStart, in: original)
            let context = enclosingContext(
                at: dot, scopes: scopes, source: masked)

            if method == "removePersistentDomain" {
                let arguments = utf16Substring(
                    original,
                    from: open + 1,
                    to: close)
                let argument = keyExpression(
                    in: arguments, label: "forName")
                    ?? firstArgument(arguments)
                let receiver = receiverExpression(
                    before: dot, in: masked)
                let normalizedArgument = normalizedDomainArgument(
                    argument,
                    source: original,
                    callOffset: dot)
                violations.append(AccountPreferenceUsageViolation(
                    path: source.path,
                    line: line,
                    keyOrUse: "removePersistentDomain",
                    reason: "whole preference-domain removal is forbidden",
                    operationFingerprint:
                        "\(receiver).removePersistentDomain(forName: \(normalizedArgument))",
                    ownership: deletionOwnership(
                        source: masked, offset: dot, context: context)))
                continue
            }

            let arguments = utf16Substring(
                original,
                from: open + 1,
                to: close)
            guard let expression = keyExpression(
                in: arguments, label: "forKey") else {
                continue
            }
            var constants = constantsBefore(
                dot,
                original: original,
                masked: masked,
                scopes: scopes)
            if context.type == "CaptureWidgetSnapshotStore" {
                constants.removeValue(forKey: "key")
                constants.removeValue(forKey: "activeOwnerKey")
            }
            if context.type == "CaptureAccountScope",
               ["storedPreferenceValue", "restorePreferenceValue"]
                .contains(context.method) {
                // `key` is the typed seam's method parameter. A same-named
                // declaration elsewhere in this large owner must not be
                // substituted for it by the file-wide constant resolver.
                constants.removeValue(forKey: "key")
            }
            let resolved = resolve(
                expression,
                constants: constants)
            if receiverKind == .mutable {
                violations.append(AccountPreferenceUsageViolation(
                    path: source.path,
                    line: line,
                    keyOrUse: resolved.key ?? resolved.use,
                    reason: "mutable UserDefaults alias is reassignment-ambiguous"))
                continue
            }
            if let violation = classify(
                resolved,
                method: method,
                path: source.path,
                line: line,
                context: context,
                entries: entries)
            {
                violations.append(violation)
            }
        }

        violations += scanCFPreferences(
            source,
            masked: masked,
            scopes: scopes,
            entries: entries)
        violations += scanAppStorage(
            source,
            masked: masked,
            scopes: scopes,
            entries: entries)
        violations += validateTrackALegacyCoupling(
            source, masked: masked, scopes: scopes)
        violations += validateTrackANormalCoupling(
            source, masked: masked, scopes: scopes)
        return violations
    }

    private static func classify(
        _ resolved: ResolvedKey,
        method: String,
        path: String,
        line: Int,
        context: (type: String?, method: String?),
        entries: [String: AccountPreferenceCatalogEntry]
    ) -> AccountPreferenceUsageViolation? {
        let violation: (String) -> AccountPreferenceUsageViolation = { reason in
            AccountPreferenceUsageViolation(
                path: path,
                line: line,
                keyOrUse: resolved.key ?? resolved.use,
                reason: reason)
        }

        if let key = resolved.key, let entry = entries[key] {
            if resolved.scoped { return nil }
            if context.type == "AccountPreferenceCompatibilityStore",
               entry.activationState == .inactiveCompatibility,
               let enclosingMethod = context.method {
                let exactMethods = [
                    "read", "write", "remove",
                    "clearLegacyCheckoutAttempt",
                    "writeLegacyCheckoutAttempt",
                    "hasLegacyStringValue", "legacyValue",
                    "persist", "restore",
                ]
                if exactMethods.contains(enclosingMethod) { return nil }
            }
            return violation(
                entry.activationState == .active
                    ? "active account preference used through raw compatibility storage"
                    : "account preference used outside its scoped or inactive compatibility seam")
        }

        if let key = resolved.key, phoneOwnedKeys.contains(key) {
            return resolved.scoped
                ? violation("phone-owned preference used through account scope")
                : nil
        }

        if let key = resolved.key, accountInfrastructureKeys.contains(key) {
            guard let owner = context.type,
                  let enclosingMethod = context.method else {
                return violation(
                    "Track-A account infrastructure has no declared owner")
            }
            let normalAllowed: Bool
            switch key {
            case "foundryx.cell.url", "foundryx.cell.authMode":
                normalAllowed =
                    owner == "CellStore"
                    && ["pair", "unpair", "load"].contains(enclosingMethod)
                    && resolved.scoped
            case "foundryx.door.url":
                normalAllowed =
                    owner == "DoorConfigStore"
                    && ["load", "save"].contains(enclosingMethod)
                    && resolved.scoped
            default:
                normalAllowed = false
            }
            if normalAllowed { return nil }
            let legacyAllowed =
                owner == "CaptureAccountScope"
                && !resolved.scoped
                && ((enclosingMethod == "adoptLegacyCellPairing"
                        && ["foundryx.cell.url", "foundryx.cell.authMode"]
                            .contains(key))
                    || (enclosingMethod == "adoptLegacyDoorPairing"
                        && key == "foundryx.door.url"))
            if legacyAllowed { return nil }
            let legacyScopedWrite =
                owner == "CaptureAccountScope"
                && resolved.scoped
                && ((enclosingMethod == "adoptLegacyCellPairing"
                        && ["foundryx.cell.url", "foundryx.cell.authMode"]
                            .contains(key))
                    || (enclosingMethod == "adoptLegacyDoorPairing"
                        && key == "foundryx.door.url"))
            if legacyScopedWrite { return nil }
            return violation(
                "Track-A account infrastructure used outside its exact owner and method")
        }

        if resolved.dynamic {
            let compactUse = resolved.use
                .replacingOccurrences(
                    of: "\\s+", with: "", options: .regularExpression)
            if context.type == "AccountSurfaceRuntime",
               context.method == "clear",
               ["removeObject", "object"].contains(method),
               compactUse == "$0" {
                // The identity boundary accepts only manifest-owned literal arrays;
                // AccountSurfaceCompletenessTests independently reflects every literal.
                return nil
            }
            if context.type == "AccountSurfaceRegistry",
               ["captureDetachSnapshot", "restoreDetachSnapshot"]
                    .contains(context.method),
               ["object", "removeObject", "set"].contains(method),
               ["key", "$0", "$0.key"].contains(compactUse) {
                // Rollback touches only detachPreferenceKeys, the closed literal list
                // owned by the 26-case manifest and independently completeness-scanned.
                return nil
            }
            if context.type == "LiveAccountDeletionContext",
               let enclosingMethod = context.method,
               ["remove", "verify"].contains(enclosingMethod),
               ["removeObject", "object"].contains(method),
               [
                    "\"\\(binding.scope).\\(key)\"",
                    "\"\\(binding.scope).\\($0.canonicalKey)\"",
                    "\"\\(binding.scope).\\($0)\"",
                    "legacyPreferenceKey",
               ].contains(compactUse) {
                return nil
            }
            if context.type == "CellStore",
               context.method == "erasePairing",
               ["removeObject", "object"].contains(method),
               [
                    "\"\\(binding.scope).\\(Self.urlKey)\"",
                    "\"\\(binding.scope).\\(Self.modeKey)\"",
               ].contains(compactUse) {
                return nil
            }
            if context.type == "DoorConfigStore",
               context.method == "erasePairing",
               ["removeObject", "object"].contains(method),
               compactUse == "\"\\(binding.scope).\\(Self.urlKey)\"" {
                return nil
            }
            if compactUse == "AuthStore.signedInMirrorKey" {
                return nil
            }
            if context.type == "CaptureWidgetSnapshotStore",
               ["key", "activeOwnerKey"].contains(compactUse) {
                return nil
            }
            if context.type == "AccountPreferenceWriteStore",
               let enclosingMethod = context.method {
                let allowedMethods = [
                    "write", "readback", "persistedValue",
                    "restore", "storedValue", "set",
                ]
                let allowedUses = [
                    "scopedKey", "key", "keyasCFString",
                ]
                if allowedMethods.contains(enclosingMethod),
                   allowedUses.contains(compactUse) {
                    return nil
                }
            }
            if context.type == "AccountPreferenceActivationStore",
               let enclosingMethod = context.method {
                let allowedMethods = [
                    "explicitValues", "persist", "storedValue",
                ]
                let allowedUses = [
                    "key(entry.canonicalKey)",
                    "scoped.key(entry.canonicalKey)",
                    "scoped.key($0.canonicalKey)",
                    "storageKey",
                    "key",
                ]
                if allowedMethods.contains(enclosingMethod),
                   allowedUses.contains(compactUse) {
                    return nil
                }
            }
            if context.type == "CaptureAccountScope",
               let enclosingMethod = context.method {
                if enclosingMethod == "scopedOwnerHasExistingState",
                   method == "object",
                   compactUse == "scoped.key($0)" {
                    return nil
                }
                let allowedMethods = [
                    "writeAccountPreference",
                    "removeAccountPreference",
                    "mutateCheckoutPreferencePair",
                    "storedPreferenceValue",
                    "restorePreferenceValue",
                ]
                let allowedUses = [
                    "scoped.key(key.canonicalKey)",
                    "scoped.key(idCanonical)",
                    "scoped.key(planCanonical)",
                    "storageKey",
                    "key",
                ]
                if allowedMethods.contains(enclosingMethod),
                   allowedUses.contains(compactUse) {
                    return nil
                }
            }
            if context.type == "AccountPreferenceCompatibilityStore" {
                let genericMethods = [
                    "read", "write", "remove",
                    "clearLegacyCheckoutAttempt",
                    "writeLegacyCheckoutAttempt",
                    "hasLegacyStringValue", "legacyValue",
                    "persist", "restore",
                ]
                let genericUses = [
                    "key", "canonicalKey", "key.canonicalKey",
                    "idKey", "planKey",
                ]
                if let method = context.method,
                   genericMethods.contains(method),
                   genericUses.contains(compactUse) {
                    return nil
                }
                if entries.values.allSatisfy({
                    $0.activationState == .inactiveCompatibility
                }),
                   context.method == "legacySignupPosted",
                   compactUse == "legacySignupKey(for:account)" {
                    return nil
                }
                if entries.values.allSatisfy({
                    $0.activationState == .inactiveCompatibility
                }),
                   context.method == "markLegacySignupPosted",
                   compactUse == "legacySignupKey(for:account)" {
                    return nil
                }
            }
            if context.type == "LegacySignupMarkerMigration",
               let enclosingMethod = context.method {
                let exactHistoricalUse =
                    compactUse == "historicalKey(identity)"
                if enclosingMethod == "snapshot",
                   exactHistoricalUse,
                   ["object", "bool"].contains(method) {
                    return nil
                }
                if enclosingMethod == "retire",
                   exactHistoricalUse,
                   ["removeObject", "object"].contains(method) {
                    return nil
                }
            }
            return violation(
                "dynamic or unresolved preference key is forbidden at this persistence use")
        }

        if let key = resolved.key {
            return violation("saved choice has no ownership classification: \(key)")
        }
        return violation("preference key could not be resolved")
    }

    private static func scanCFPreferences(
        _ source: AccountPreferenceSourceFile,
        masked: String,
        scopes: [Scope],
        entries: [String: AccountPreferenceCatalogEntry]
    ) -> [AccountPreferenceUsageViolation] {
        var result: [AccountPreferenceUsageViolation] = []
        for name in ["CFPreferencesCopyAppValue", "CFPreferencesSetAppValue"] {
            for match in regexMatches("\\b\(name)\\s*\\(", in: masked) {
                let offset = match.range.location
                let context = enclosingContext(
                    at: offset, scopes: scopes, source: masked)
                guard let open = masked.utf16Offset(
                    after: match.range.location + match.range.length - 1),
                      let close = matchingParen(
                        in: masked, openUTF16Offset: open)
                else { continue }
                let arguments = utf16Substring(
                    source.text, from: open + 1, to: close)
                let first = firstArgument(arguments)
                let constants = constantsBefore(
                    offset,
                    original: source.text,
                    masked: masked,
                    scopes: scopes)
                let resolved = resolve(first, constants: constants)
                if let violation = classify(
                    resolved,
                    method: name == "CFPreferencesSetAppValue" ? "set" : "object",
                    path: source.path,
                    line: lineNumber(
                        atUTF16Offset: offset, in: source.text),
                    context: context,
                    entries: entries)
                {
                    result.append(violation)
                }
            }
        }
        return result
    }

    private static func scanAppStorage(
        _ source: AccountPreferenceSourceFile,
        masked: String,
        scopes: [Scope],
        entries: [String: AccountPreferenceCatalogEntry]
    ) -> [AccountPreferenceUsageViolation] {
        var result: [AccountPreferenceUsageViolation] = []
        for match in regexMatches(
            "@(?:AppStorage|SceneStorage)\\s*\\(", in: masked)
        {
            guard let open = masked.utf16Offset(
                after: match.range.location + match.range.length - 1),
                  let close = matchingParen(
                    in: masked, openUTF16Offset: open)
            else { continue }
            let expression = firstArgument(utf16Substring(
                source.text, from: open + 1, to: close))
            let constants = constantsBefore(
                match.range.location,
                original: source.text,
                masked: masked,
                scopes: scopes)
            let resolved = resolve(expression, constants: constants)
            if let violation = classify(
                resolved,
                method: "AppStorage",
                path: source.path,
                line: lineNumber(
                    atUTF16Offset: match.range.location,
                    in: source.text),
                context: enclosingContext(
                    at: match.range.location,
                    scopes: scopes,
                    source: masked),
                entries: entries)
            {
                result.append(violation)
            }
        }
        return result
    }

    private static func defaultsAliases(
        in original: String,
        masked: String
    ) -> DefaultsAliases {
        var aliases = DefaultsAliases(
            trusted: ["defaults"],
            mutable: [])
        for match in regexMatches(
            "\\b([A-Za-z_][A-Za-z0-9_]*)\\s*:\\s*UserDefaults\\b",
            in: masked)
        {
            aliases.trusted.insert(
                substring(masked, range: match.range(at: 1)))
        }
        for match in regexMatches(
            "\\b(let|var)\\s+([A-Za-z_][A-Za-z0-9_]*)[^=\\n]*=\\s*UserDefaults\\s*(?:\\.\\s*standard|\\()",
            in: masked)
        {
            let binding = substring(masked, range: match.range(at: 1))
            let name = substring(masked, range: match.range(at: 2))
            if binding == "var" {
                aliases.mutable.insert(name)
            } else {
                aliases.trusted.insert(name)
            }
        }
        for match in regexMatches(
            "\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\([^)]*\\)\\s*->\\s*UserDefaults",
            in: masked)
        {
            aliases.trusted.insert(
                substring(masked, range: match.range(at: 1)))
        }
        let declaredVars = Set(regexMatches(
            "\\bvar\\s+([A-Za-z_][A-Za-z0-9_]*)\\b",
            in: masked
        ).map {
            substring(masked, range: $0.range(at: 1))
        })
        var changed = true
        while changed {
            changed = false
            let knownAlternation = aliases.trusted
                .union(aliases.mutable)
                .map(NSRegularExpression.escapedPattern(for:))
                .sorted()
                .joined(separator: "|")
            guard !knownAlternation.isEmpty else { break }
            let pattern =
                "\\b(let|var|if\\s+let|guard\\s+let)\\s+"
                + "([A-Za-z_][A-Za-z0-9_]*)[^=\\n]*=\\s*"
                + "(\(knownAlternation))\\b"
            for match in regexMatches(pattern, in: masked) {
                let binding = substring(masked, range: match.range(at: 1))
                let name = substring(masked, range: match.range(at: 2))
                let source = substring(masked, range: match.range(at: 3))
                let becomesMutable =
                    binding == "var" || aliases.mutable.contains(source)
                if becomesMutable {
                    let wasTrusted = aliases.trusted.remove(name) != nil
                    if aliases.mutable.insert(name).inserted || wasTrusted {
                        changed = true
                    }
                } else if !aliases.mutable.contains(name),
                          aliases.trusted.insert(name).inserted {
                    changed = true
                }
            }
            let assignmentPattern =
                "\\b([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*"
                + "(\(knownAlternation))\\b"
            for match in regexMatches(assignmentPattern, in: masked) {
                let name = substring(masked, range: match.range(at: 1))
                guard declaredVars.contains(name) else { continue }
                let wasTrusted = aliases.trusted.remove(name) != nil
                if aliases.mutable.insert(name).inserted || wasTrusted {
                    changed = true
                }
            }
        }
        _ = original
        return aliases
    }

    private static func stringConstants(
        in original: String,
        masked: String
    ) -> [String: String] {
        var constants: [String: String] = [:]
        let pattern =
            "\\b(?:let|var)\\s+([A-Za-z_][A-Za-z0-9_]*)[^=\\n]*="
        for match in regexMatches(pattern, in: masked) {
            let name = substring(masked, range: match.range(at: 1))
            let start = match.range.location + match.range.length
            let remainder = utf16Substring(
                original,
                from: start,
                to: min(original.utf16.count, start + 300))
            let expression = firstLineExpression(remainder)
            if !expression.isEmpty { constants[name] = expression }
        }
        return constants
    }

    private static func constantsBefore(
        _ offset: Int,
        original: String,
        masked: String,
        scopes: [Scope]
    ) -> [String: String] {
        var constants = uniqueStringConstants(
            in: original, masked: masked)
        let methodStart = scopes
            .filter {
                $0.kind == "func"
                    && $0.start <= offset
                    && offset <= $0.end
            }
            .max { $0.start < $1.start }?
            .start ?? 0
        let local = stringConstants(
            in: utf16Substring(
                original, from: methodStart, to: offset),
            masked: utf16Substring(
                masked, from: methodStart, to: offset))
        constants.merge(local) { _, nearestLocal in nearestLocal }
        return constants
    }

    private static func uniqueStringConstants(
        in original: String,
        masked: String
    ) -> [String: String] {
        let pattern =
            "\\b(?:let|var)\\s+([A-Za-z_][A-Za-z0-9_]*)[^=\\n]*="
        var values: [String: [String]] = [:]
        for match in regexMatches(pattern, in: masked) {
            let name = substring(masked, range: match.range(at: 1))
            let start = match.range.location + match.range.length
            let remainder = utf16Substring(
                original,
                from: start,
                to: min(original.utf16.count, start + 300))
            let expression = firstLineExpression(remainder)
            if !expression.isEmpty {
                values[name, default: []].append(expression)
            }
        }
        return Dictionary(uniqueKeysWithValues: values.compactMap {
            name, expressions in
            expressions.count == 1 ? (name, expressions[0]) : nil
        })
    }

    private static func resolve(
        _ expression: String,
        constants: [String: String],
        visited: Set<String> = []
    ) -> ResolvedKey {
        var expression = expression
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while expression.hasSuffix(" as CFString") {
            expression.removeLast(" as CFString".count)
            expression = expression.trimmingCharacters(in: .whitespaces)
        }
        if let range = expression.range(
            of: #"\.key\s*\("#,
            options: .regularExpression),
           expression.hasSuffix(")") {
            let inner = String(expression[range.upperBound..<expression.index(
                before: expression.endIndex)])
            let resolved = resolve(
                inner, constants: constants, visited: visited)
            return ResolvedKey(
                key: resolved.key,
                use: expression,
                scoped: true,
                dynamic: resolved.dynamic)
        }
        if expression.contains("\\(")
            || expression.contains("+")
            || expression.contains("String(format:")
            || expression.contains(".appending") {
            return ResolvedKey(
                key: nil, use: expression, scoped: false, dynamic: true)
        }
        if expression.hasPrefix("\""), expression.hasSuffix("\""),
           expression.count >= 2 {
            return ResolvedKey(
                key: String(expression.dropFirst().dropLast()),
                use: expression,
                scoped: false,
                dynamic: false)
        }
        let identifier = expression
            .split(separator: ".")
            .last
            .map(String.init) ?? expression
        if let value = constants[identifier], !visited.contains(identifier) {
            return resolve(
                value,
                constants: constants,
                visited: visited.union([identifier]))
        }
        return ResolvedKey(
            key: nil, use: expression, scoped: false, dynamic: true)
    }

    private static func defaultsReceiver(
        before dot: Int,
        masked: String,
        aliases: DefaultsAliases
    ) -> DefaultsReceiver {
        let prefix = utf16Substring(
            masked, from: max(0, dot - 160), to: dot)
        if prefix.range(
            of: #"\bUserDefaults\s*(?:\.\s*standard|\([^)]*\))\s*$"#,
            options: .regularExpression) != nil {
            return .trusted
        }
        let receiver = prefix.range(
            of: #"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*$"#,
            options: .regularExpression)
            .map { String(prefix[$0]) }
            .map {
                $0.replacingOccurrences(
                    of: "()", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        guard let receiver else { return .no }
        if aliases.mutable.contains(receiver) { return .mutable }
        return aliases.trusted.contains(receiver) ? .trusted : .no
    }

    private static func keyExpression(
        in arguments: String,
        label: String
    ) -> String? {
        let characters = Array(arguments)
        var paren = 0
        var bracket = 0
        var brace = 0
        var inString = false
        var escaped = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            switch character {
            case "\"": inString = true
            case "(": paren += 1
            case ")": paren -= 1
            case "[": bracket += 1
            case "]": bracket -= 1
            case "{": brace += 1
            case "}": brace -= 1
            default: break
            }
            if paren == 0, bracket == 0, brace == 0,
               index + label.count <= characters.count,
               String(characters[index..<index + label.count]) == label {
                var cursor = index + label.count
                while cursor < characters.count,
                      characters[cursor].isWhitespace {
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == ":" {
                    return expressionPrefix(
                        String(characters[(cursor + 1)...]))
                }
            }
            index += 1
        }
        return nil
    }

    private static func firstArgument(_ arguments: String) -> String {
        expressionPrefix(arguments)
    }

    private static func expressionPrefix(_ text: String) -> String {
        var paren = 0
        var bracket = 0
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "(": paren += 1
            case ")": paren -= 1
            case "[": bracket += 1
            case "]": bracket -= 1
            case "," where paren == 0 && bracket == 0:
                return String(text[..<index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            default: break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstLineExpression(_ text: String) -> String {
        var value = ""
        var inString = false
        var escaped = false
        for character in text {
            if character == "\n" && !inString { break }
            value.append(character)
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            }
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func declarationScopes(in masked: String) -> [Scope] {
        var scopes: [Scope] = []
        let pattern =
            "\\b(class|struct|enum|extension|func)\\s+([A-Za-z_][A-Za-z0-9_]*)[^\\{]*\\{"
        for match in regexMatches(pattern, in: masked) {
            let kind = substring(masked, range: match.range(at: 1))
            let name = substring(masked, range: match.range(at: 2))
            let open = match.range.location + match.range.length - 1
            if let close = matchingBrace(
                in: masked, openUTF16Offset: open) {
                scopes.append(Scope(
                    kind: kind,
                    name: name,
                    start: match.range.location,
                    end: close))
            }
        }
        return scopes
    }

    private static func enclosingContext(
        at offset: Int,
        scopes: [Scope],
        source: String
    ) -> (type: String?, method: String?) {
        let enclosing = scopes.filter {
            $0.start <= offset && offset <= $0.end
        }
        let type = enclosing
            .filter { $0.kind != "func" }
            .max { $0.start < $1.start }?
            .name
        let method = enclosing
            .filter { $0.kind == "func" }
            .max { $0.start < $1.start }?
            .name
        _ = source
        return (type, method)
    }

    private static func deletionOwnership(
        source: String,
        offset: Int,
        context: (type: String?, method: String?)
    ) -> String? {
        guard context.type == "AccountDeletionModel",
              context.method == "live" else { return nil }
        for match in regexMatches(
            "\\beraseLocal\\s*:\\s*\\{", in: source)
        {
            let open = match.range.location + match.range.length - 1
            guard let close = matchingBrace(
                in: source, openUTF16Offset: open) else { continue }
            if open < offset, offset < close {
                return "AccountDeletionModel.live->eraseLocal"
            }
        }
        return nil
    }

    private static func receiverExpression(
        before dot: Int,
        in masked: String
    ) -> String {
        let prefix = utf16Substring(
            masked, from: max(0, dot - 180), to: dot)
        if let range = prefix.range(
            of: #"\bUserDefaults\s*\.\s*standard\s*$"#,
            options: .regularExpression) {
            return String(prefix[range])
                .replacingOccurrences(
                    of: "\\s+", with: "", options: .regularExpression)
        }
        if let range = prefix.range(
            of: #"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?\s*$"#,
            options: .regularExpression) {
            return String(prefix[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "<unresolved-receiver>"
    }

    private static func normalizedDomainArgument(
        _ argument: String,
        source: String,
        callOffset: Int
    ) -> String {
        let compact = argument
            .replacingOccurrences(
                of: "\\s+", with: "", options: .regularExpression)
        if compact == "Bundle.main.bundleIdentifier" {
            return "Bundle.main.bundleIdentifier"
        }
        if compact == "domain" {
            let prefix = utf16Substring(
                source, from: max(0, callOffset - 500), to: callOffset)
            if prefix.range(
                of: #"\b(?:if\s+)?let\s+domain"#
                    + #"\s*=\s*Bundle\s*\.\s*main\s*\.\s*bundleIdentifier\b"#,
                options: .regularExpression) != nil {
                return "Bundle.main.bundleIdentifier"
            }
        }
        return compact
    }

    private static func validateTrackALegacyCoupling(
        _ source: AccountPreferenceSourceFile,
        masked: String,
        scopes: [Scope]
    ) -> [AccountPreferenceUsageViolation] {
        let methods = scopes.filter { $0.kind == "func" }
        guard methods.contains(where: {
            ["adoptLegacyCellPairing", "adoptLegacyDoorPairing"]
                .contains($0.name)
        }) else { return [] }

        func body(_ name: String, maskedBody: Bool = false) -> String {
            guard let scope = methods.first(where: { $0.name == name }) else {
                return ""
            }
            return utf16Substring(
                maskedBody ? masked : source.text,
                from: scope.start,
                to: scope.end + 1)
        }

        let cell = body("adoptLegacyCellPairing")
        let door = body("adoptLegacyDoorPairing")
        let owner = body("adoptLegacyPairingRecord")
        let maskedCell = body(
            "adoptLegacyCellPairing", maskedBody: true)
        let maskedDoor = body(
            "adoptLegacyDoorPairing", maskedBody: true)
        func defaultsCall(
            _ operation: String,
            key: String,
            scoped: Bool,
            in methodBody: String
        ) -> Bool {
            callArguments(
                receiver: "defaults",
                operation: operation,
                in: methodBody
            ).contains {
                argument(
                    in: $0,
                    label: "forKey",
                    equals: scoped ? "scoped.key(\(key))" : key)
            }
        }
        func adoptionCall(in methodBody: String) -> Bool {
            callArguments(
                receiver: nil,
                operation: "adoptLegacyKeychainSecretIfNeeded",
                in: methodBody
            ).contains {
                argument(in: $0, label: "service", equals: "service")
                    && argument(
                        in: $0,
                        label: "scope",
                        equals: "scoped.scope")
            }
        }
        let cellComplete =
            cell.contains("foundryx.cell.url")
            && cell.contains("foundryx.cell.authMode")
            && defaultsCall(
                "string", key: "urlKey", scoped: false, in: maskedCell)
            && defaultsCall(
                "string", key: "modeKey", scoped: false, in: maskedCell)
            && defaultsCall(
                "set", key: "urlKey", scoped: true, in: maskedCell)
            && defaultsCall(
                "set", key: "modeKey", scoped: true, in: maskedCell)
            && adoptionCall(in: maskedCell)
        let doorComplete =
            door.contains("foundryx.door.url")
            && defaultsCall(
                "string", key: "urlKey", scoped: false, in: maskedDoor)
            && defaultsCall(
                "set", key: "urlKey", scoped: true, in: maskedDoor)
            && adoptionCall(in: maskedDoor)
        let maskedOwner = maskNonCode(owner)
        func ownerRoutes(
            _ operation: String,
            service: String
        ) -> Bool {
            callArguments(
                receiver: nil,
                operation: operation,
                in: maskedOwner
            ).contains {
                argument(in: $0, label: "defaults", equals: "defaults")
                    && argument(in: $0, label: "scoped", equals: "scoped")
                    && argument(
                        in: $0,
                        label: "service",
                        equals: "services.\(service)")
            }
        }
        let servicesComplete =
            owner.contains("cell: \"com.goforgeit.foundryx.cell\"")
            && owner.contains("door: \"com.goforgeit.foundryx.door\"")
            && ownerRoutes(
                "adoptLegacyCellPairing", service: "cell")
            && ownerRoutes(
                "adoptLegacyDoorPairing", service: "door")
        guard cellComplete, doorComplete, servicesComplete else {
            let first = methods.first(where: {
                ["adoptLegacyCellPairing", "adoptLegacyDoorPairing"]
                    .contains($0.name)
            })!
            return [AccountPreferenceUsageViolation(
                path: source.path,
                line: lineNumber(
                    atUTF16Offset: first.start, in: source.text),
                keyOrUse: "Track-A legacy pairing registry",
                reason: "Track-A Cell URL/authMode, Door URL, and coupled Keychain services must be registered atomically")]
        }
        return []
    }

    private static func validateTrackANormalCoupling(
        _ source: AccountPreferenceSourceFile,
        masked: String,
        scopes: [Scope]
    ) -> [AccountPreferenceUsageViolation] {
        let typeNames = Set(scopes.filter {
            ["class", "struct", "enum", "actor"].contains($0.kind)
        }.map(\.name))
        var violations: [AccountPreferenceUsageViolation] = []

        func appendViolation(owner: String, reason: String) {
            guard let scope = scopes.first(where: { $0.name == owner }) else {
                return
            }
            violations.append(AccountPreferenceUsageViolation(
                path: source.path,
                line: lineNumber(atUTF16Offset: scope.start, in: source.text),
                keyOrUse: "Track-A \(owner) registry",
                reason: reason))
        }

        func methodBodies(
            owner: String,
            name: String
        ) -> [String] {
            guard let ownerScope = scopes.first(where: {
                $0.name == owner && $0.kind != "func"
            }) else { return [] }
            return scopes.filter {
                $0.kind == "func"
                    && $0.name == name
                    && ownerScope.start < $0.start
                    && $0.end < ownerScope.end
            }.map {
                utf16Substring(masked, from: $0.start, to: $0.end + 1)
            }.filter {
                containsCall(#"\b(?:defaults|secretStore)\s*\."#, in: $0)
            }
        }

        func allOperationalBodies(
            owner: String,
            name: String,
            satisfy contract: (String) -> Bool
        ) -> Bool {
            let bodies = methodBodies(owner: owner, name: name)
            return !bodies.isEmpty && bodies.allSatisfy(contract)
        }

        func defaultsCall(
            _ operation: String,
            key: String,
            in body: String
        ) -> Bool {
            callArguments(
                receiver: "defaults",
                operation: operation,
                in: body
            ).contains {
                argument(
                    in: $0,
                    label: "forKey",
                    equals: "scoped.key(Self.\(key))")
                    || argument(
                        in: $0,
                        label: "forKey",
                        equals: "scoped.key(\(key))")
            }
        }

        func secretCall(
            _ operation: String,
            in body: String
        ) -> Bool {
            callArguments(
                receiver: "secretStore",
                operation: operation,
                in: body
            ).contains {
                argument(
                    in: $0,
                    label: "service",
                    equals: "keychainService")
                    && argument(
                        in: $0,
                        label: "account",
                        equals: "scoped.scope")
            }
        }

        if typeNames.contains("CellStore") {
            let hasKeys =
                source.text.contains("\"foundryx.cell.url\"")
                && source.text.contains("\"foundryx.cell.authMode\"")
            let pairComplete = allOperationalBodies(
                owner: "CellStore", name: "pair"
            ) {
                defaultsCall("set", key: "urlKey", in: $0)
                    && defaultsCall("set", key: "modeKey", in: $0)
                    && secretCall("remove", in: $0)
                    && secretCall("replace", in: $0)
            }
            let unpairComplete = allOperationalBodies(
                owner: "CellStore", name: "unpair"
            ) {
                defaultsCall("removeObject", key: "urlKey", in: $0)
                    && defaultsCall(
                        "removeObject", key: "modeKey", in: $0)
                    && secretCall("remove", in: $0)
            }
            let loadComplete = allOperationalBodies(
                owner: "CellStore", name: "load"
            ) {
                defaultsCall("string", key: "urlKey", in: $0)
                    && defaultsCall("string", key: "modeKey", in: $0)
                    && secretCall("read", in: $0)
            }
            let serviceDeclared = source.text.contains(
                "\"com.goforgeit.foundryx.cell\"")
            if !hasKeys || !serviceDeclared || !pairComplete
                || !unpairComplete || !loadComplete {
                appendViolation(
                    owner: "CellStore",
                    reason: "Track-A Cell pair/unpair/load must each couple URL/authMode with the required Keychain operation")
            }
        }

        if typeNames.contains("DoorConfigStore") {
            let hasKey = source.text.contains("\"foundryx.door.url\"")
            let loadComplete = allOperationalBodies(
                owner: "DoorConfigStore", name: "load"
            ) {
                defaultsCall("string", key: "urlKey", in: $0)
                    && secretCall("read", in: $0)
            }
            let saveComplete = allOperationalBodies(
                owner: "DoorConfigStore", name: "save"
            ) {
                defaultsCall("set", key: "urlKey", in: $0)
                    && secretCall("replace", in: $0)
            }
            let serviceDeclared = source.text.contains(
                "\"com.goforgeit.foundryx.door\"")
            if !hasKey || !serviceDeclared || !loadComplete || !saveComplete {
                appendViolation(
                    owner: "DoorConfigStore",
                    reason: "Track-A Door load/save must each couple URL with the required Keychain operation")
            }
        }
        return violations
    }

    private static func containsCall(
        _ pattern: String,
        in text: String
    ) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func callArguments(
        receiver: String?,
        operation: String,
        in text: String
    ) -> [String] {
        let escapedOperation = NSRegularExpression.escapedPattern(
            for: operation)
        let pattern: String
        if let receiver {
            pattern =
                "\\b"
                + NSRegularExpression.escapedPattern(for: receiver)
                + "\\s*\\.\\s*" + escapedOperation + "\\s*\\("
        } else {
            pattern = "\\b" + escapedOperation + "\\s*\\("
        }
        let units = Array(text.utf16)
        return regexMatches(pattern, in: text).compactMap { match in
            if receiver == nil {
                var cursor = match.range.location - 1
                while cursor >= 0,
                      [9, 10, 11, 12, 13, 32].contains(units[cursor]) {
                    cursor -= 1
                }
                if cursor >= 0, units[cursor] == 46 {
                    return nil
                }
            }
            let open = match.range.location + match.range.length - 1
            guard let close = matchingParen(
                in: text, openUTF16Offset: open) else { return nil }
            return utf16Substring(text, from: open + 1, to: close)
        }
    }

    private static func argument(
        in arguments: String,
        label: String,
        equals expected: String
    ) -> Bool {
        guard let value = keyExpression(
            in: arguments, label: label) else { return false }
        return value.replacingOccurrences(
            of: "\\s+", with: "", options: .regularExpression)
            == expected
    }

    private static func maskNonCode(_ text: String) -> String {
        let units = Array(text.utf16)
        var output = units
        let space = UInt16(32)
        let newline = UInt16(10)
        let slash = UInt16(47)
        let star = UInt16(42)
        let quote = UInt16(34)
        let hash = UInt16(35)
        let backslash = UInt16(92)
        var index = 0
        var blockDepth = 0
        var inLineComment = false
        var inString = false
        var escaped = false
        var stringHashes = 0
        var stringQuotes = 1
        while index < units.count {
            let current = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            if inLineComment {
                if current == newline {
                    inLineComment = false
                } else {
                    output[index] = space
                }
            } else if blockDepth > 0 {
                if current == slash, next == star {
                    output[index] = space
                    output[index + 1] = space
                    blockDepth += 1
                    index += 1
                } else if current == star, next == slash {
                    output[index] = space
                    output[index + 1] = space
                    blockDepth -= 1
                    index += 1
                } else if current != newline {
                    output[index] = space
                }
            } else if inString {
                if current != newline { output[index] = space }
                let closesQuotes = current == quote
                    && (stringHashes > 0 || !escaped)
                    && (stringQuotes == 1
                        || (index + 2 < units.count
                            && units[index + 1] == quote
                            && units[index + 2] == quote))
                if closesQuotes {
                    let quoteEnd = index + stringQuotes
                    let hashesClose = quoteEnd + stringHashes <= units.count
                        && (0..<stringHashes).allSatisfy {
                            units[quoteEnd + $0] == hash
                        }
                    if hashesClose {
                        for cursor in index..<quoteEnd + stringHashes {
                            if output[cursor] != newline {
                                output[cursor] = space
                            }
                        }
                        index = quoteEnd + stringHashes - 1
                        inString = false
                        escaped = false
                    }
                } else if stringHashes == 0 {
                    if escaped {
                        escaped = false
                    } else if current == backslash {
                        escaped = true
                    }
                }
            } else if current == slash, next == slash {
                output[index] = space
                output[index + 1] = space
                inLineComment = true
                index += 1
            } else if current == slash, next == star {
                output[index] = space
                output[index + 1] = space
                blockDepth = 1
                index += 1
            } else if current == quote
                || current == hash {
                var hashes = 0
                var quoteIndex = index
                while quoteIndex < units.count,
                      units[quoteIndex] == hash {
                    hashes += 1
                    quoteIndex += 1
                }
                guard quoteIndex < units.count,
                      units[quoteIndex] == quote else {
                    index += 1
                    continue
                }
                let triple = quoteIndex + 2 < units.count
                    && units[quoteIndex + 1] == quote
                    && units[quoteIndex + 2] == quote
                stringHashes = hashes
                stringQuotes = triple ? 3 : 1
                for cursor in index..<quoteIndex + stringQuotes {
                    output[cursor] = space
                }
                index = quoteIndex + stringQuotes - 1
                inString = true
            }
            index += 1
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func matchingParen(
        in text: String,
        openUTF16Offset: Int
    ) -> Int? {
        matchingDelimiter(
            in: text,
            openUTF16Offset: openUTF16Offset,
            open: "(",
            close: ")")
    }

    private static func matchingBrace(
        in text: String,
        openUTF16Offset: Int
    ) -> Int? {
        matchingDelimiter(
            in: text,
            openUTF16Offset: openUTF16Offset,
            open: "{",
            close: "}")
    }

    private static func matchingDelimiter(
        in text: String,
        openUTF16Offset: Int,
        open: Character,
        close: Character
    ) -> Int? {
        let units = Array(text.utf16)
        let openUnit = String(open).utf16.first!
        let closeUnit = String(close).utf16.first!
        var depth = 0
        for index in openUTF16Offset..<units.count {
            if units[index] == openUnit { depth += 1 }
            if units[index] == closeUnit {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private static func callStartOffset(
        before dot: Int,
        in text: String
    ) -> Int {
        let units = Array(text.utf16)
        var index = max(0, dot - 1)
        while index > 0 {
            let scalar = UnicodeScalar(units[index])
            guard let scalar,
                  CharacterSet.alphanumerics.contains(scalar)
                    || units[index] == 95
                    || units[index] == 46
                    || units[index] == 40
                    || units[index] == 41
                    || CharacterSet.whitespaces.contains(scalar)
            else { break }
            if units[index] == 10 { break }
            index -= 1
        }
        return index == 0 ? 0 : index + 1
    }

    private static func lineNumber(
        atUTF16Offset offset: Int,
        in text: String
    ) -> Int {
        utf16Substring(text, from: 0, to: offset)
            .reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
    }

    private static func regexMatches(
        _ pattern: String,
        in text: String
    ) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return regex.matches(
            in: text,
            range: NSRange(location: 0, length: text.utf16.count))
    }

    private static func substring(
        _ text: String,
        range: NSRange
    ) -> String {
        guard let range = Range(range, in: text) else { return "" }
        return String(text[range])
    }

    private static func utf16Substring(
        _ text: String,
        from: Int,
        to: Int
    ) -> String {
        let view = text.utf16
        let lower = view.index(view.startIndex, offsetBy: max(0, from))
        let upper = view.index(
            view.startIndex,
            offsetBy: min(view.count, max(from, to)))
        return String(decoding: view[lower..<upper], as: UTF16.self)
    }
}

private extension String {
    func utf16Offset(after offset: Int) -> Int? {
        offset < utf16.count ? offset : nil
    }
}
