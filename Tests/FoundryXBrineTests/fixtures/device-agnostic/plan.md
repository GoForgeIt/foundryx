# Plan — device_agnostic_recording_source

Author-role R13 revision. No timelines, commit, or lifecycle transition.

## 0. Binding method

Base-move check: FoundryX `origin/main` remains
`8dc73ccd5e35503f8e5bb324a63b89d2553c99be`, identical to R12. R13 pins this unchanged base and
re-derives every retained line citation at it. Repository probes use the detached worktree
`/private/tmp/r12-plans.rdswuD/foundryx-origin-main` at
`8dc73ccd5e35503f8e5bb324a63b89d2553c99be`. Actual trimmed output is adjacent. A parse error,
unexpected empty population, or mismatch blocks implementation and requires a plan correction.

R12 T8 seam probe:

```sh
rg --sort path -n 'final class AmbientCardBroker|func run\(|func dismissed|static func post\(|static func postPreview|private static func deliver|center\.add|testAppIdentityTransitionClearsBrokerAndBindsDelayedWork' \
  App/AmbientCards.swift App/AmbientNotifier.swift Tests/FoundryXBrineTests/AccountDataIsolationFeatureTests.swift
```

R12 actual output:

```text
App/AmbientCards.swift:17:final class AmbientCardBroker: ObservableObject {
App/AmbientCards.swift:34:    func run(
App/AmbientCards.swift:116:    nonisolated static func dismissed(
App/AmbientNotifier.swift:154:    static func post(candidate: AmbientCandidate, outcome: AmbientRouteOutcome?,
App/AmbientNotifier.swift:258:    static func postPreview() {
App/AmbientNotifier.swift:267:    private static func deliver(title: String, body: String, preview: Bool,
App/AmbientNotifier.swift:303:                center.add(req) { _ in
Tests/FoundryXBrineTests/AccountDataIsolationFeatureTests.swift:473:    func testAppIdentityTransitionClearsBrokerAndBindsDelayedWork() throws {
```

R13 drift-sensitive anchor probe at `8dc73ccd`:

```sh
awk 'NR==465||NR==472||NR==749||NR==758||NR==770||NR==779||NR==835||NR==846||NR==872||NR==882||NR==885||NR==892||NR==893||NR==894||NR==898||NR==902||NR==904||NR==906||NR==909||NR==918||NR==931||NR==1113||NR==1114 {print FNR ":" $0}' Sources/FoundryXKit/DeviceManager.swift
awk 'NR==62||NR==417||NR==1339 {print FNR ":" $0}' Sources/FoundryXKit/CaptureAccountScope.swift
awk 'NR==2760||NR==2781||NR==2792||NR==2794 {print FNR ":" $0}' Sources/FoundryXKit/CaptureManager.swift
```

R13 actual output:

```text
465:    public func reconnect() {
472:    public func forget() {
749:    public func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
758:    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
770:                autoReconnect(userInitiated: false)   // automatic: dormant when no saved device
779:    private func handleRestoredPeripheral(_ p: CBPeripheral, central c: CBCentralManager) {
835:    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
846:        p.discoverServices([OmiUUID.audioService, OmiUUID.batteryService, OmiUUID.storageService])
872:    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
882:        switch OmiReconnectPolicy.onDisconnect(autoConnect: autoConnect) {
885:        case .reissuePendingConnect:
892:            setState(.disconnected)
893:            bind(p)
894:            c.connect(p, options: nil)
898:    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
902:                p.discoverCharacteristics([OmiUUID.audioDataChar, OmiUUID.codecChar], for: svc)
904:                p.discoverCharacteristics([OmiUUID.batteryLevelChar], for: svc)
906:                p.discoverCharacteristics([OmiUUID.buttonTriggerChar], for: svc)
909:                p.discoverCharacteristics([OmiUUID.storageDataChar, OmiUUID.storageControlChar], for: svc)
918:    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
931:                emitSourceState(.streaming)   // triggers ambient capture
1113:    public func reconnect() {}
1114:    public func forget() {}
62:    /// Signed-out on-device capture is a first-class `acct-none` scope. Generation,
417:    /// background restoration is unauthorized and currentRoot fails closed.
1339:    public static func currentRoot() -> URL {
2760:        case .streaming:
2781:                log?.info("capture \(active?.captureId ?? "?"): Omi reconnected within grace → resumed (no new session)")
2792:                   let resumeId = CaptureManager.resumableCaptureId(baseDir: baseDir,
2794:                   resumeSession(captureId: resumeId) {
```

Provenance footnote: both required engine Describes were attempted first on 2026-07-28 with the
working `grpcurl -plaintext -import-path proto -proto anvil.proto ... anvil.AnvilService/Describe`
form; this
authoring sandbox denied the local gRPC dial (`connect: operation not permitted`), so no engine state
is synthesized.

R6 integrity correction: R5 disposed `brine check features` as “executed,” but that command exits 1
because FoundryX has no `.brine` manifest. That was a composed execution claim and remains named
permanently in this ledger. The real validators are `scripts/ci-gates.sh swift` (SwiftPM +
BrineSwiftCore) and `scripts/ci-gates.sh iosbrine` (same logic suite on iOS).

Clean-layout precondition: `foundryx/` must have sibling checkouts at `../grain` and
`../brine-private`, because `Package.swift:12,14` uses
`../grain/platforms/grain-swift` and `../brine-private/runners/implementations/swift`.
R7 constructed the clean layout with:

```sh
root=$(mktemp -d /private/tmp/r7-device.XXXXXX)
mkdir -p "$root/foundryx"
git -C foundryx archive origin/main | tar -x -C "$root/foundryx"
ln -s /Users/nicholasrinard/Development/grain "$root/grain"
ln -s /Users/nicholasrinard/Development/brine-private "$root/brine-private"
```

Actual output from three path assertions:

```text
OK foundryx/Package.swift
OK grain/platforms/grain-swift/Package.swift
OK brine-private/runners/implementations/swift/Package.swift
```

Literal-path census executed against that clean layout:

```sh
for p in foundryx/features foundryx/Tests/FoundryXBrineTests foundryx/scripts/ci-gates.sh \
 foundryx/Package.swift foundryx/project.yml \
 foundryx/Sources/FoundryXKit/CaptureSourceRegistry.swift \
 foundryx/Sources/FoundryXKit/AudioFrameSource.swift \
 foundryx/Sources/FoundryXKit/DeviceManager.swift \
 foundryx/Sources/FoundryXKit/CaptureAccountScope.swift \
 foundryx/Sources/FoundryXKit/OmiOfflineSync.swift \
 foundryx/Sources/FoundryXKit/CaptureManager.swift \
 foundryx/Sources/FoundryXKit/OmiRestorationSpool.swift \
 foundryx/App/FoundryXAppDelegate.swift \
 foundryx/Sources/FoundryXKit/AmbientSignalShipper.swift \
 foundryx/Sources/FoundryXKit/CaptureWAL.swift; do
  test -e "$root/$p" || { echo "MISSING $p"; exit 1; }; echo "OK $p"
done
```

Actual output: 15 `OK <literal path>` lines, from `foundryx/features` through
`foundryx/Sources/FoundryXKit/CaptureWAL.swift`; no `MISSING` line.

Every user-visible behavior follows Gherkin → step definitions → demonstrated red → simplest green → refactor. Feature steps drive the real Swift/package/app seam. Fakes are allowed only behind an existing or explicitly declared test-seam override and must fail loudly when misconfigured.

## 1. Open human decision — NICK-DECISION-ROUTE-PRIMARY

**Status: OPEN. This is Nick's to answer and no agent's to resolve.** Five consecutive independent reviews recorded it as an open human gate. The R5 rewrite deleted it and recorded *"Nick's universal intent governs"*; that closure was **invalid** — an agent resolved a human gate — and it is reversed here. No answer or default is proposed.

**The question.** May a route-backed device — a Bluetooth audio-route input, e.g. an HFP headset — be the **primary, always-on ambient sensor**? Or is a route-backed device eligible to connect and record while the always-on ambient role requires a stream-backed device?

Binding quote: **“it could be any external bluetooth recording device.”**

**Why the binding quote does not answer it.** Eligibility to connect and record does not choose the
always-on role. On iOS a Bluetooth audio-route input is commonly 8/16 kHz and occupies the shared
audio route for the whole handset while active. Nick must choose with that fidelity/system-route
consequence visible and must not read the drafting posture as an answer.

**Answer A:** route-backed devices may hold the primary ambient role. Coverage is maximal—any
headset the user already owns works as the ambient sensor. T10-A adds `.audioRoute` to R1 bullet 2,
R4 bullet 5, and §3 Feature 1's Bluetooth-audio-route row, and proves the shared-route/fidelity
consequence visibly.

**Answer B:** route-backed devices connect and record, but the primary ambient role requires a
stream-backed device. T10-B leaves `.audioRoute` out of those three locations and proves an
actionable visible refusal—never silent fallback—and distinguishes ambient-role ineligibility from
stale liveness. A user who owns only an HFP headset therefore has no always-on ambient sensor.

### NICK-GATE (delivery)

Nick must answer NICK-DECISION-ROUTE-PRIMARY before T10 begins. T0–T9 do not change the conditional
ambient-role locations. **Surface the full decision block above verbatim to Nick, including the
technical consequence, both answers, and all three conditional locations.** Record Nick’s answer
in `foundryx-hearth/decisions/` before executing exactly one of T10-A or T10-B. Final implementation
review cannot close with neither or both.

## 2. Plan-phase decisions, retained

- **PD-SOURCE-INTEGRATION:** represent capture shapes as data behind `CaptureSourceRegistry`; keep BLE stream and handset audio route adapters separate; selection is preference-first and capability-checked.
- **PD-CONNECT-UX:** one connect affordance and one merged device list on the device page; capture surfaces show status, not a second connector.
- **PD-DEVICE-STATE:** account-scoped multi-device records, one active selection, explicit signed-out hold, deterministic legacy migration.
- **PD-ARCHIVE-IDENTITY:** additive `.capture-device.json` sidecar. The wire-stable marker mapping
  is `.bleStream → "omi"` and `.audioRoute`/`.builtInMic → "phoneMic"`; aliases preserve existing
  bytes. Readers retain legacy support. Post-migration missing identity is fail-loud/unknown, never guessed.
- **PD-LIVENESS:** on-device usable-audio receipts evaluated with receiver-controlled time; ship a privacy-safe status record through the existing ambient shipper and a dedicated `ambient-device.jsonl` leg.
- **PD-AMBIENT-SILENCE-PROOF:** assert authorization at the Kit action gate and census every notification, Live Activity, and widget posting seam with a negative control.

## 3. Tasks

### Scenario-owner ledger (derived from every `Then`)

Derivation rule: list every `Then`/`And` following a `Then`; reduce each to the production capability
that must make it observable; assign the scenario to one task whose declared capability set contains
the entire union. Dependencies are the tasks that produce prerequisite state used by those Thens,
not merely related Givens.

| ID | Spec scenario | Required Then capabilities | Sole owner | Required dependencies |
|---|---|---|---|---|
| S01 | each device shape connects through the one experience | rendered-list,capture-finalize,archive-attribution | T5 | T1,T4 |
| S02 | unusable audio is refused without corrupting capture | rendered-refusal,capture-integrity,device-availability | T5 | T1,T4 |
| S03 | absent capabilities are not invented | rendered-capabilities,gap-copy | T5 | T1,T3 |
| S04 | system reconnect preserves continuity while user detach stays detached | reconnect,resume-same-capture,detach-persistence | T4 | T1,T2,T3 |
| S05 | another device substitutes without vendor priority | active-selection,preference-handoff,archive-attribution | T5 | T1,T2,T4 |
| S06 | legacy pairing and history survive an account-scoped upgrade | pairing-migration,rendered-history,account-isolation | T5 | T2,T4 |
| S07 | device-agnostic history does not trigger onboarding | rendered-history,onboarding-suppression | T5 | T2,T4 |
| S08 | signed-out upgrade does not leak or discard legacy pairing | pairing-migration,account-isolation | T2 | none |
| S09 | active-device failure is visible within the bound | bounded-liveness,both-status-surfaces,last-heard-age | T6 | T5 |
| S10 | a device that has never delivered usable audio is never healthy | bounded-liveness,both-status-surfaces,last-heard-age | T6 | T5 |
| S11 | an idle remembered device cannot answer for the active device | active-device-liveness,both-status-surfaces | T6 | T2,T5 |
| S12 | no device and no active device remain distinct | bounded-liveness,both-status-surfaces | T6 | T2,T5 |
| S13 | later valid activity recovers from bad status evidence | malformed-evidence-recovery,both-status-surfaces | T6 | T5 |
| S14 | personal device identity does not cross the handset boundary | privacy-status-handoff,account-correlation-resistance | T7 | T2 |
| S15 | a device transition alone makes nothing speak unprompted | zero-agent-actions,zero-notifications,zero-live-activity,zero-widget | T8 | T6 |
| S16 | only an allowed ambient trigger causes agent action | authorized-agent-action | T8 | none |
| S17 | every emitted agent action has an allowed cause | cause-complete-agent-actions | T8 | none |
| P01 | in-flight user capture stays silent across device/liveness transition and source switch | zero-notifications,zero-live-activity,capture-integrity,source-switch-silence | T8 | T4,T6 |
| P02 | surface-open device transition does not create or alert any posting seam | zero-agent-actions,zero-notifications,zero-live-activity,zero-widget | T8 | T6 |

Capability rule: the sole owner must declare that it **asserts every Then**; each required
capability must be in the implementation set of the owner or a declared earlier dependency.
“Implements capability” and “asserts Then” are separate sets. T4 asserts S04 and carries the paths
needed to drive the complete seam; T1 implements reconnect policy, T2 implements detach
persistence, and T3 implements continuity/gap state before T4 executes the complete
scenario. T0 compares the scenario-name population from `spec.md` with the ledger and applies both
subset checks. Missing/extra/duplicate scenarios, a non-asserting owner, or an unimplemented
capability exits nonzero.

### T0 — Baseline, feature ownership, and red ledger

Paths: `foundryx/features/`, `foundryx/Tests/FoundryXBrineTests/`, `foundryx/scripts/ci-gates.sh`, `foundryx/Package.swift`, `foundryx/project.yml`.

Verify before starting:

```sh
rg -n '^\s*(Scenario|Scenario Outline):' foundryx/features
rg -n 'FoundryXBrineTests|ci-gates|test' foundryx/{Package.swift,project.yml,scripts/ci-gates.sh}
```

Executed output (trimmed): scenarios were non-empty beginning
`action-chat-organization.feature:7,11,15,20`; package/project output names
`FoundryXBrineTests` and the iOS-simulator target.

Map every spec scenario to exactly one capable owner and admit only the two named plan-level
carry-forward scenarios P01/P02. The census property is spec names ⊆ ledger, with extras exactly
equal to that allow-list:
```sh
ruby -e 's=File.read("spec.md"); p=File.read("plan.md"); a=s.scan(/^\s*Scenario(?: Outline)?:\s*(.+)$/).flatten.sort; b=p.scan(/^\| [SP]\d+ \| ([^|]+) \|/).flatten.map(&:strip).sort; allow=["in-flight user capture stays silent across device/liveness transition and source switch","surface-open device transition does not create or alert any posting seam"].sort; abort((a-b).inspect) unless (a-b).empty?; abort((b-a).inspect) unless (b-a).sort==allow; abort "duplicate ledger scenario" unless b.size==b.uniq.size; puts "spec=#{a.size} ledger=#{b.size} plan_level=#{allow.size} unique=#{b.uniq.size}"; puts "SPEC_SUBSET_AND_ALLOWLIST_MATCH"'
```

Actual output:

```text
spec=17 ledger=19 plan_level=2 unique=19
SPEC_SUBSET_AND_ALLOWLIST_MATCH
```

The runnable capability check uses the 19 ledger tuples as `rows`, a separate `impl` map of
task→capabilities built, and an `asserts` map of task→scenario IDs asserted:

```js
// Save this block as /tmp/r10-capability-check.js or pipe it to `node`.
const fs = require('node:fs');
const markdown = fs.readFileSync(process.argv[2] || 'plan.md', 'utf8');
const rows = [...markdown.matchAll(/^\| ([SP]\d+) \| [^|]+ \| ([^|]+) \| (T\d+) \| ([^|]+) \|$/gm)]
  .map(([,id,required,owner,deps]) => [id, required.split(',').map(x=>x.trim()), owner,
    deps.trim()==='none' ? [] : deps.split(',').map(x=>x.trim())]);
if (rows.length !== 19) throw new Error(`ledger parse returned ${rows.length}, expected 19`);
const impl={T1:['rendered-list','rendered-refusal','rendered-capabilities','device-availability','reconnect'],T2:['pairing-migration','account-isolation','active-selection','preference-handoff','detach-persistence','account-correlation-resistance'],T3:['gap-copy','resume-same-capture'],T4:['capture-finalize','capture-integrity','archive-attribution'],T5:['rendered-list','rendered-refusal','rendered-capabilities','rendered-history','onboarding-suppression','both-status-surfaces'],T6:['bounded-liveness','active-device-liveness','last-heard-age','malformed-evidence-recovery'],T7:['privacy-status-handoff'],T8:['zero-agent-actions','zero-notifications','zero-live-activity','zero-widget','source-switch-silence','authorized-agent-action','cause-complete-agent-actions']};
const asserts={T2:['S08'],T4:['S04'],T5:['S01','S02','S03','S05','S06','S07'],T6:['S09','S10','S11','S12','S13'],T7:['S14'],T8:['S15','S16','S17','P01','P02']};
if(process.env.R10_WRONG_OWNER) rows.find(r=>r[0]==='S04')[2]='T1';
let errors=[]; for(const [id,req,owner,deps] of rows){if(!(asserts[owner]||[]).includes(id)) errors.push(`${id}: ${owner} does not assert every Then`); const built=new Set([owner,...deps].flatMap(t=>impl[t]||[])); const miss=req.filter(c=>!built.has(c)); if(miss.length) errors.push(`${id}: unimplemented ${miss.join(',')}`)}
for(const [id,,owner,deps] of rows) for(const dep of deps)
  if(Number(dep.slice(1)) >= Number(owner.slice(1))) errors.push(`${id}: dependency ${dep} is not earlier than ${owner}`);
if(errors.length){console.error(errors.join('\n'));process.exit(1)}
console.log(`${rows.length} scenarios; every owner asserts every Then; all required capabilities implemented by owner or declared earlier dependency`);
```

The executable `rows` population is parsed directly from `plan.md`. R11 actual green output:
`19 scenarios; every owner asserts every Then; all required capabilities implemented by owner or declared earlier dependency`.
Wrong-owner mutation (trimmed: three dependency-order lines omitted)
(`R10_WRONG_OWNER=1 node /tmp/r10-capability-check.js plan.md`) outputs
`S04: T1 does not assert every Then`; exit `1`.

R10 strip-each-dependency falsification, executed from the declared fresh detached worktree while
parsing the live markdown: S01,S02,S03,S04,S05,S06,S09,S10,S11,S12,S13,S14 each report
`strip-deps => RED`; S07,S15,P01,P02 report `DECORATIVE` because their owners implement their
complete required capability sets. S04 is load-bearing.

T0 also creates `Tests/FoundryXBrineTests/then-capabilities.json`, keyed by exact normalized
scenario name and exact normalized `Then`/post-Then `And` text. The verifier parses `spec.md`
directly (R9 census: `17` scenarios, `52` Then clauses), requires every clause exactly once with at
least one capability token, and requires the per-scenario token union to equal the ledger's
Required-Then column in both directions. P01/P02 are parsed from their new feature and obey the same
rule. Mutation “delete one token mapping or one Then clause mapping” reds. It also parses task
numbers and rejects every dependency whose task number is not strictly lower than its owner.
The checked-in implementation is a Swift test utility invoked by
`swift test --filter FoundryXBrineTests.ThenCapabilityMapTests`. Its plan-time executable
population/token smoke proof is:

```sh
ruby -e 's=File.readlines(ARGV[0]);p=File.read(ARGV[1]);n=0;sc=0;after=false;s.each{|l|if l=~/^\s*Scenario(?: Outline)?:/;sc+=1;after=false elsif l=~/^\s*Then\s+/;n+=1;after=true elsif l=~/^\s*And\s+/&&after;n+=1 elsif l=~/^\s*(Given|When|But)\s+/;after=false end};abort "counts changed: then=#{n} scenarios=#{sc}" unless n==52&&sc==17;rows=p.scan(/^\| ([SP]\d+) \| [^|]+ \| ([^|]+) \| (T\d+) \| ([^|]+) \|$/);abort "ledger rows=#{rows.size}" unless rows.size==19;p01=rows.find{|r|r[0]=="P01"};abort "P01 missing capability capture-integrity" unless p01[1].split(",").include?("capture-integrity");puts "TOTAL_THEN_CLAUSES=#{n} SCENARIOS=#{sc} LEDGER_ROWS=#{rows.size}";puts "GREEN P01 capture-integrity mapped; dependency T4 precedes owner T8"' spec.md plan.md
cp plan.md /private/tmp/r11-device-plan.md
sed -i '' 's/zero-notifications,zero-live-activity,capture-integrity,source-switch-silence/zero-notifications,zero-live-activity,source-switch-silence/' /private/tmp/r11-device-plan.md
ruby -e 's=File.readlines(ARGV[0]);p=File.read(ARGV[1]);n=0;sc=0;after=false;s.each{|l|if l=~/^\s*Scenario(?: Outline)?:/;sc+=1;after=false elsif l=~/^\s*Then\s+/;n+=1;after=true elsif l=~/^\s*And\s+/&&after;n+=1 elsif l=~/^\s*(Given|When|But)\s+/;after=false end};abort "counts changed: then=#{n} scenarios=#{sc}" unless n==52&&sc==17;rows=p.scan(/^\| ([SP]\d+) \| [^|]+ \| ([^|]+) \| (T\d+) \| ([^|]+) \|$/);abort "ledger rows=#{rows.size}" unless rows.size==19;p01=rows.find{|r|r[0]=="P01"};abort "P01 missing capability capture-integrity" unless p01[1].split(",").include?("capture-integrity");puts "TOTAL_THEN_CLAUSES=#{n} SCENARIOS=#{sc} LEDGER_ROWS=#{rows.size}";puts "GREEN P01 capture-integrity mapped; dependency T4 precedes owner T8"' spec.md /private/tmp/r11-device-plan.md
```

R11 actual output:

```text
TOTAL_THEN_CLAUSES=52 SCENARIOS=17 LEDGER_ROWS=19
GREEN P01 capture-integrity mapped; dependency T4 precedes owner T8
P01 missing capability capture-integrity
```

The final command exits `1`. It runs the unmodified checker against an artifact copy whose P01 row
was mutated. This smoke proof catches the R9 P01 omission; the Swift test remains responsible for
the stronger exact-text mapping for all 52 clauses and both plan-level scenarios. Column-content
deletions are the Swift verifier's obligation through its both-directions token-union check; the
smoke block's P01/`capture-integrity` pair is a historical regression pin only. A test selecting
zero cases is a STOP.

T0's **first act** is to run `scripts/ci-gates.sh swift` in the declared two-sibling layout at
`8dc73ccd`, requiring `0 failures (0 unexpected)` and `CI GATES PASS`; actual executed/skipped counts
are recorded, never presumed. No baseline exists yet at this base. The following is provenance from
`296db278d819fdfc3845df3d302441b2fee20972`, not the R13 baseline:

```text
Executed 1030 tests, with 5 tests skipped and 0 failures (0 unexpected) in 133.965 seconds
CI GATES PASS
```

The R7
authoring sandbox could not run the gate: its first attempt failed writing
`~/.cache/clang/.../SwiftShims...pcm: Operation not permitted`; after redirecting both module
caches into the clean root, SwiftPM still failed
`sandbox-exec: sandbox_apply: Operation not permitted` and reported `CI GATES FAILED: swift-test`.
That is retained only as authoring-harness provenance, not as the tree baseline.

### T1 — Source shapes, registry, discovery, capability refusal

Paths: `foundryx/Sources/FoundryXKit/CaptureSourceRegistry.swift`, `AudioFrameSource.swift`, `DeviceManager.swift`, and the existing audio-input discovery/presentation files found by:

```sh
rg -n 'CaptureSourceRegistry|AudioInputDiscovering|availableInputs|discoverBluetoothMics|prototypeRows' \
  foundryx/Sources foundryx/App foundryx/Tests
```

Executed output (trimmed): `CaptureSourceRegistryTests.swift:15: AudioInputDiscovering`;
`:24: availableInputs()`; `DevicePagePresentationTests.swift:86: prototypeRows`.

Each discovered device maps to an explicit shape/profile, capability set, stable device identity,
and adapter. Unknown/unusable framing is an honest refusal, never coerced into Omi bytes.
T1 implements the reconnect policy contract: a system disconnect while auto-connect remains
enabled yields `.reissuePendingConnect`; manual reconnect remains a distinct user gesture.

Proof: T1 supplies shape/capability and reconnect prerequisites consumed by T4/T5-owned rows.
Mutation: vendor-name branching or first-discovered selection reds the consuming T5 scenarios;
suppressing reconnect policy state reds S04 in T4.

### T2 — Account-scoped device store and privacy key

Paths: `foundryx/Sources/FoundryXKit/CaptureAccountScope.swift`, existing pairing/preference stores discovered with:

```sh
rg -n 'paired|preferred|active.*device|accountKeyMaterial|acct-none|currentRoot' foundryx/Sources
```

Executed output (trimmed): `CaptureAccountScope.swift:62: acct-none`;
`:417: currentRoot fails closed`; `:1339: currentRoot()`.

Build account-scoped multi-device records and migration. Signed-out records remain in `acct-none` and do not cross into a signed-in account without the explicit migration rule.
T2 implements detach persistence: `forget()` writes the account-scoped explicit-detach state, and
automatic restoration/relaunch cannot reactivate it until a user reconnect clears that state.

Name the `DeviceRef` key source: derive from `FoundryAuth.accountKeyMaterial` with domain separation. When no account secret exists, do not emit an outbound `DeviceStatusRecord`; record a typed local `status_withheld(no_account_key)` outcome. Never derive from an enumerable scope name or invent a fallback.

Proof: account-switch isolation, migration idempotence, signed-out hold, correlation resistance, and withheld-status feature. Mutation: fixed/global HMAC key reds.

### T3 — BLE gap-window state machine and truthful outcomes

Paths: `foundryx/Sources/FoundryXKit/DeviceManager.swift`, `OmiOfflineSync.swift`, `CaptureManager.swift`.

Verify before starting:

```sh
rg -n 'beginGapSyncWindow|endGapSyncWindow|gapSyncFinished|didConnect|didDisconnectPeripheral|discoverServices|maybeBeginGapSync|enum Outcome|framesEmitted|linkDropped' \
  foundryx/Sources/FoundryXKit/{DeviceManager.swift,OmiOfflineSync.swift}
rg -n 'paused|capture.*active|emitSourceState' foundryx/Sources/FoundryXKit/{CaptureManager.swift,DeviceManager.swift,OmiRestorationSpool.swift}
```

Executed output (trimmed): `DeviceManager.swift:582: beginGapSyncWindow`;
`:654: gapSyncFinished`; `OmiOfflineSync.swift` returns the engine `Outcome`, `framesEmitted`, and
`linkDropped` sites; the second command finds paused and `emitSourceState` paths.

Model every window close as data; do not maintain a plan-time fixed call-site count. `DeviceManager` may report transport facts, but whether a disconnect interrupted active capture is supplied by `CaptureManager`, which owns capture/paused state.
T3 implements `resume-same-capture`: the interruption/gap state carries the active conversation
identity through reconnect and refuses creation of a replacement conversation.

Required mapping includes the reachable sequence `didConnect → begin window → disconnect before discoverServices/engine`. If it followed interrupted active capture, publish `.nothingToRecover` because the unread span remains on-device for the next reconnect; if no active capture was interrupted, close silently. At most one outcome per opened window; exactly one only for a window tagged at open as following interrupted active capture.

Proof: a red-first feature drops the link while the window is open but before service discovery, then reconnects and re-pulls the same span without ever showing “unrecoverable.” Also cover engine success/no frames/abort/budget/link-drop paths. Mutation: publish `.unrecoverable` for the no-engine disconnect; the scenario reds.

### T4 — Identity-bearing restoration spool and archive sidecar

Paths: `foundryx/Sources/FoundryXKit/OmiRestorationSpool.swift`, `AudioFrameSource.swift`,
`CaptureManager.swift`, `DeviceManager.swift`, `OmiReconnectPolicy.swift`,
`foundryx/App/FoundryXAppDelegate.swift`.

Verify before starting:

```sh
rg -n 'OmiRestorationSpool\(|attach\(to:|protocol AudioFrameSource|resumableCaptureId|capture-device|capture-source' \
  foundryx/App foundryx/Sources foundryx/Tests
```

Executed output (trimmed): `FoundryXAppDelegate.swift:47: OmiRestorationSpool`;
`:66: spool.attach(to:)`; `OmiRestorationSpool.swift:197: resumableCaptureId`;
`OmiReconnectTests.swift:78-79` constructs and attaches the spool.

Carry a typed `CaptureDeviceContext` from the app composition root into the spool; do not ask `OmiRestorationSpool.init` to discover account/device identity it does not possess. The context contains the already-resolved device id/display name/shape and account scope. If scope or identity is blocked during background restoration, fail loud and defer capture/resume; never write a placeholder sidecar.

Write the sidecar at both normal and spool capture creation sites. Widen resume matching to `(shape, deviceId)` only when the sidecar exists; preserve the byte-identical legacy marker arm for pre-migration captures. Determine pre/post migration from durable conversation start metadata/capture-id time; filesystem mtime is forbidden. An undatable capture takes the legacy arm with a typed diagnostic; it is never guessed post-migration. Assert that a legacy Omi recording still renders “Omi.”

**S04 seam decision: choose (a), the stronger spec-shaped answer.** The spec requires
scenario-level proof that a system link drop reconnects without reopening the app; policy-only or
`@ble-hardware` evidence is insufficient. T4 therefore wraps the full CoreBluetooth discovery
surface—`CBCentralManager`, `CBPeripheral`, `CBService`, and `CBCharacteristic`—injects those
protocols into `DeviceManager`, and supplies a fake that can drive
`centralManager(_:didDisconnectPeripheral:)` end to end despite `CBPeripheral.init`
and `CBService`/`CBCharacteristic` initializers being `NS_UNAVAILABLE`. The production adapter wraps
all four concrete types. `DeviceManager`'s stored peripheral (`:155`), restored peripheral (`:170`),
stored characteristic declarations, and discovered-peripheral map move behind the seam types.
The complete current delegate/function anchors are `willRestoreState :749`,
`centralManagerDidUpdateState :758`, `handleRestoredPeripheral :779`, `didConnect :835`,
`didDiscoverServices :898`, `didDiscoverCharacteristicsFor :918`, and
`didDisconnectPeripheral :872`; state update calls `autoReconnect(userInitiated:false) :770`. The
`@ble-hardware` lane remains an additional XCTSkip-gated physical-path check, not the acceptance
proof.

The truthful automatic chain is `didDisconnectPeripheral` (`DeviceManager.swift:872`) →
`OmiReconnectPolicy.onDisconnect(autoConnect:)` (`:882`) →
`.reissuePendingConnect` (`:885-895`) → `setState(.disconnected)` `:892`; `bind(p)` `:893`;
`central.connect(p, options:nil)` `:894`. Connect completion then drives `didConnect` `:835` →
`discoverServices` `:846` → `didDiscoverServices` `:898` →
`discoverCharacteristics` `:902/:904/:906/:909` →
`didDiscoverCharacteristicsFor` `:918` → `emitSourceState(.streaming)` `:931` →
`CaptureManager`'s `.streaming` arm `:2760`, in-grace resume `:2781`, and cold
`resumableCaptureId`/`resumeSession` arm `:2792-2794`, which resume the same capture id.
`autoReconnect(userInitiated:false)` is not in that chain; its state-update call is `:770`. S04 drives
the injected fake through that entire production-unit sequence—drop, connect reissued, connect
completes, services discovered, audio characteristic discovered, `.streaming`, same capture id.
No half-proof may inject `.streaming` directly into `CaptureManager`.
Located mutations: remove `bind/connect` at `:893-894` ⇒ S04 reds while
`OmiReconnectTests` and `omi-always-reconnect.feature` remain green; independently suppress
`:931`'s `.streaming` emission ⇒ S04's same-capture Then reds while those pre-existing suites remain
green.

The canImport(CoreBluetooth) methods are
`reconnect()` at `:465` and `forget()` at `:472`; manual `reconnect()` appears only in a distinct
user-gesture assertion, while `forget()` drives detach persistence. The no-CoreBluetooth stubs are
`:1113/:1114` and are not acceptance anchors.

`App/` is compiled by neither SwiftPM `FoundryXBrineTests` nor the hostless iOS test target.
Extract the composition into a Kit-level factory callable both by `FoundryXAppDelegate` and
`FoundryXBrineTests`; the end-to-end spool assertion runs through that factory. Mutation: omit the
context at the factory boundary (not an uncompiled App-only line); the spool feature reds.

### T5 — One rendered UX and honest attribution/gap copy

Paths: device-page and capture/timeline presentation files located by:

```sh
rg -n 'DevicePagePresentation|DeviceScreen|CaptureLiveStatus|Unknown device|gap.*recover' \
  foundryx/Sources foundryx/App foundryx/Tests
```

Executed output (trimmed): `RootView.swift:1177: CaptureLiveStatus.phase`;
`CaptureLiveActivityTests.swift` contains the real phase assertions.

T5 owns `Tests/FoundryXBrineTests/fixtures/s05-device-shape-interpretation.json`. The artifact
records rememberable registry order `omi: 0`, `appleWatch: 1`, `bluetoothMic: 2`, and states that
`builtInMic`/phone mic is not a rememberable external device. S05 therefore uses `omi` (first) and
`bluetoothMic` (last among rememberable devices). Its scenario loads this artifact and fails if the
registry order changes, resolving the frozen spec's ambiguous “ranks last” wording without editing
the spec.

Render one connector/list, honest capabilities, active source, archive attribution, and total `GapRecoveryOutcome` copy. `.nothingToRecover` must never render “audio was not recoverable.” Post-migration missing sidecar shows unknown with a diagnostic; legacy captures preserve legacy attribution. A known capability refusal must reach this rendered surface with an actionable reason.

Proof follows the scenario-owner ledger and its derived dependencies. Mutation: brand/vendor copy
and wrong gap copy red.

### T6 — Liveness evaluator and bounded recovery

Paths: existing ambient/capture status code discovered with:

```sh
rg -n 'usable.*audio|receipt|stale|fresh|heartbeat|CaptureLiveActivity|Widget' foundryx/Sources foundryx/App
```

Executed output (trimmed): non-empty census includes receipt/stale sites in app presentation and
`CaptureLiveActivityTests`.

Add an injectable monotonic test clock. Evaluate freshness from usable-audio receipt time, not BLE connection. Malformed input and clock regression fail loud and recover on the next valid receipt. Bound stale/fresh transitions and expose them consistently on device and capture surfaces.

Proof: feature clock advances without real waits; connected-but-silent becomes stale; valid audio
recovers. Route-role ineligibility is absent from T0–T9 and belongs only to T10-B if Nick selects B.

### T7 — Status repository and shipper

Paths: `foundryx/Sources/FoundryXKit/AmbientSignalShipper.swift`, `CaptureWAL.swift`, `CaptureAccountScope.swift`.

Verify before starting:

```sh
rg -n 'shipPending|struct Watermark|decisionsURL|cardsURL|readWatermark|send\(' \
  foundryx/Sources/FoundryXKit/AmbientSignalShipper.swift
```

Executed output: `:90 decisionsURL`, `:91 cardsURL`, `:159 shipPending`, `:160 readWatermark`,
`:191 send(records)`, `:200 struct Watermark`.

Add `ambient-device.jsonl` under the capture/account repository and a `devices` watermark. Add an
explicit decoder using `decodeIfPresent(.devices) ?? 0` so an installed two-field watermark
preserves `decisions` and `cards` offsets rather than replaying history. Test that upgrade case.
Preserve existing single-batch transport semantics.

Proof: real shipper request contains privacy-safe status, forbidden fields are absent, 200 advances all included offsets, failure advances none, and signed-out/no-key emits no outbound device record.

### T8 — Ambient silence authorization

Paths: notification, Live Activity, widget, and Kit action-gate files returned by:

```sh
rg -n 'UNUserNotificationCenter|center\.add|ActivityKit|WidgetCenter|reload|playbook|mention|authorized' \
  foundryx/Sources foundryx/App
```

Executed output (trimmed): `AmbientNotifier.swift:21: UNUserNotificationCenterDelegate`,
`:93/:131: UNUserNotificationCenter.current()`, plus playbook authorization sites.

Build gates at the **four** production legs—agent dispatch, notification, Live Activity, and
widget—and make four the census population floor; shrinking the census below four is a STOP.
Treatment transitions remain byte-identical until a playbook match or `@` mention authorizes action;
each leg has a negative control proving its executing target can observe an authorized effect.

`App/` is compiled by neither SwiftPM `FoundryXBrineTests` nor the hostless
`FoundryXiOSTests` target, and the repository's sole notification post is
`App/AmbientNotifier.swift:303 center.add(...)`. T8 therefore applies the same Kit-factory extraction
used by T4: move the production posting decision and payload construction into a
`Sources/FoundryXKit` unit behind a `NotificationPosting` protocol; keep
`UNUserNotificationCenter` as the thin App adapter. The extraction owns all three decision entries:
`post` (`:154`), `postPreview` (`:258`), and `deliver`'s authorization switch (`:314-327`).
The cause-bearing authorization decision is the same extracted Kit unit: it owns
`AmbientNotifier.post`'s route/answer switch (`:163-212`), including the owner gate at `:179` and
playbook arm `:188-198`, and returns typed notification, dispatch, dismissal, or refuse effects.
`AmbientCardBroker.dismissed`/`logOutcome` are nonisolated Foundation-only code, not
`@MainActor`/SwiftUI; move their `ambient-cards.jsonl` record writing into that Kit unit.
`FoundryXBrineTests` is the executing target for
S15/P01/P02's zero-notification Thens. It injects a recording poster at the actual production
decision seam, asserts zero posts for device/liveness transitions, and proves observability with an
authorized playbook/mention negative control that records exactly one announcement. A source-text
census of `App/AmbientNotifier.swift` is not acceptance evidence.

`AmbientCardBroker.run` (`App/AmbientCards.swift:34-48`) is a thin effect applier, not a decision:
it applies navigation and pending seed from the typed Kit effect. The same cause-bearing Kit
decision writes the durable `ambient-cards.jsonl` outcome and returns the effect, so S16/S17 assert
both the record and returned effect from a unit that actually received `AmbientRouteOutcome`;
tests do not invent an authorization cause downstream. S15/P02's zero-agent-action assertion runs
through the production route-decision entry and observes no record/effect, while an authorized
playbook/mention negative control proves the observation can go non-zero.

T8 also owns
`Tests/FoundryXBrineTests/AccountDataIsolationFeatureTests.swift:473`: its source-text assertions
at `:498-499` for
`CaptureAccountScope.perform(as:)` and the account-root append are moved to the new Kit decision
unit (or rewritten as behavioral seam assertions), never weakened after their old
`AmbientNotifier.swift` strings move.

The Live Activity and widget bodies are iOS-only (`canImport(ActivityKit/WidgetKit) && os(iOS)`).
Their zero/update controls execute in `FoundryXiOSTests` via
`scripts/ci-gates.sh compile iosbrine`, not macOS SwiftPM. The notification and agent-decision legs
execute in `FoundryXBrineTests` under `swift` and again under `compile iosbrine`.

Author two red-first plan-level scenarios in the same T8 feature/steps:

- **P01 in-flight capture:** Given a live user-started capture is open, When a device/liveness
  transition and a source switch occur, Then no alert is posted, no Live Activity is created,
  existing capture identity remains, and the source switch is status-only unless a registered
  playbook or explicit mention authorizes action.
- **P02 surface-open arm:** Given a device or status surface is open, When a device transition
  occurs, Then the agent-dispatch seam receives zero actions and notification, Live Activity, and
  widget posting seams receive zero create/update/alert posts **on account of that device/liveness
  transition** (`spec.md:112-114`). Legitimate capture-status updates remain governed by P01 and do
  not violate P02 merely because a device surface is open.

Proof: targeted feature/unit gates plus census. P01's located mutation is
`CaptureLiveActivityController.swift:85-89`: allow the update-during-recording arm to call
`start(...)`; under `compile iosbrine` the scenario reds on Live Activity creation and lost capture
identity. P02's mutation
is an otherwise-unconditional posting-seam call tagged with the device/liveness transition cause.

### T9 — Full verification and handoff

Run these concrete gates:

- `scripts/ci-gates.sh swift` — Swift package + BrineSwiftCore scenarios;
- `scripts/ci-gates.sh compile iosbrine` — `compile` first runs xcodegen because no `.xcodeproj`
  is tracked, then `iosbrine` runs the FoundryXiOSTests logic suite and the separate
  `FoundryXKeychainProof` / `PairingKeychainIntegrationTests` lane;
- `scripts/ci-gates.sh compile uiproof` — `VALID_PHASES` guarantees xcodegen-backed compile precedes
  the rendered/simulator proof. At `8dc73ccd`, uiproof selects four methods: phone-mic recording,
  ambient speech, foreground restoration, and live-transcript restoration.

The full no-argument `scripts/ci-gates.sh` subsumes all four plus gates/leak/flake/lint. Re-run every
named mutation. No timeline, commit, push, or release.

Close-gate load note: explicitly inspect and rerun
`PhoneMicCaptureTests.testPhoneMicRecordingFinalizesThroughNormalPath` and
`ConversationCardTests.testFinalizeBodyCarriesTimesAndLocationWhenAuthorized` if either flakes
under the full load; neither may be omitted or rationalized as unrelated.
`AccountDataIsolationFeatureTests.testAppIdentityTransitionClearsBrokerAndBindsDelayedWork` is an
expected-to-change T8 test and must pass with its new Kit-bound containment assertion. Run
notification and agent-decision controls under `swift`; run Live Activity, widget, and the P01
located mutation under `compile iosbrine`.

Independent reviewers found five and later twelve available iPhone devices. The R7 author's
CoreSimulatorService XPC failure is authoring-sandbox provenance only. On the implementation host,
`compile iosbrine` and `compile uiproof` are the runnable compositions.

### T10-A — route-backed primary ambient sensor

Gate: Nick selected Answer A. Add `.audioRoute` only at the conditional role/resume locations, then prove primary ambient capture and visible fidelity/shared-route behavior.

### T10-B — stream-backed primary ambient sensor only

Gate: Nick selected Answer B. Preserve route-backed connect/record/finalize, leave `.audioRoute` out of primary-role/resume rules, and prove the actionable visible refusal.

T10-A and T10-B are mutually exclusive. Automated close checks require exactly one recorded Nick decision and exactly one matching task result.

## 4. Review-finding disposition

| Finding | Disposition |
|---|---|
| Carry-forward M1 | **Fixed:** P01 covers live user-started capture, device/liveness transition, zero alert/creation, and the source-switch boundary. |
| Carry-forward M2 | **Fixed:** P02 supplies the surface-open arm across agent, notification, Live Activity, and widget posting seams. |
| Carry-forward L1 | **Fixed:** T5's named interpretation artifact resolves “ranks last” as `bluetoothMic` among rememberable devices, records `omi 0 / appleWatch 1 / bluetoothMic 2`, and excludes built-in mic; NICK-GATE prevents work on the conditional locations until Nick answers. |
| R1-H1 | **Fixed:** resume identity is shape + device, not vendor; T4 owns both normal and spool paths. |
| R1-H2/M1 | **Fixed:** reconnect/detach assigned to executable UX task; unrecoverable copy implemented from total outcome data. |
| R1-M2/M3/L1/L2 | **Mooted-by-method / fixed:** privacy claims are behavioral; full Nick decision retained; citations are probes; injectable clock. |
| R2-H3 | **Fixed:** scenario ownership follows the seam that can execute every `Then`; contributing tasks own reds. |
| R2-H4 | **Fixed:** outcome closes at a capture-aware state machine, with success and no-engine paths. |
| R2-M4/M5/M6 | **Fixed:** repository boundary, durable migration discriminator, opaque HMAC device reference. |
| R2-L4/L5/L6 | **Mooted-by-method / fixed:** anchors are nonbinding; census uses actual funnel; contradictory scenario corrected. |
| R3-H5 | **Fixed:** pre-discovery disconnect is `.nothingToRecover` when an interrupted capture tagged the window; scenario drops while window is open. |
| R3-H6 | **Fixed:** app composition root injects `CaptureDeviceContext`; blocked identity holds loudly; spool end-to-end red. |
| R3-M7 | **Fixed:** interrupted-capture truth comes from `CaptureManager`, not inferred in `DeviceManager`. |
| R3-M8 | **Fixed:** key source and signed-out withholding behavior are explicit and tested. |
| R3-L7/L8 | **Fixed:** no fixed close-count assertion; shipper checkpoint matches all-or-nothing batch semantics. |
| R3-L9 | **Fixed:** T5 owns a rendered known-refusal assertion. |
| R4-H7 | **Fixed:** all eleven probes ran; the four broken/blind regexes are corrected and outputs are adjacent. |
| R4-H8 | **Fixed:** S01–S17 have one sole owner in the ledger; no prose supplies a competing owner. |
| R4-H9/H12 | **Fixed:** the full decision consequences and the explicit durable marker mapping are restored without answering the gate. |
| R4-H10/H11/H13 | **Fixed:** spool proof uses a compiled Kit factory; real `ci-gates.sh swift/iosbrine` validators replace the nonexistent checker; two-field watermark decoding preserves history offsets. |
| R4-M9/M10/L10/L11 | **Fixed:** undatable/legacy behavior and R3-L9 are explicit; T3 probes engine terms; cwd is stated. |
| R5-H14 | **Fixed and permanently recorded as composed execution:** `brine check features` is removed; real Swift/iosbrine commands and honest sandbox errors are recorded. |
| R5-H15/H16 | **Fixed:** S12 is T6-owned; S06 is T5-owned with all rendered-history/account Thens intact. |
| R5-H17 | **Fixed:** route-role ineligibility exists only in conditional T10-B. |
| R5-M11/M12 | **Fixed:** dependencies derive from every Then; the executed census and capability-subset checks both pass 17/17. |
| R5-L12/L13 | **Fixed:** Nick receives the full block verbatim; T9 names the exact ci-gates phases and their subsumption. |
| R6-H18 | **Fixed across R7/R8:** R7 composed `compile iosbrine`; R8 composes `compile uiproof`; two independent reviewer green Swift baselines supersede the authoring-sandbox note. |
| R6-H19 | **Fixed:** T4 solely asserts all S04 Thens, depends on T1–T3, and includes `DeviceManager.swift` plus capture/restoration paths. |
| R6-H20 | **Fixed:** the runnable check separates implementation from assertion capability and the wrong-S04-owner mutation exits 1. |
| R6-M13/L14/L15 | **Fixed:** R5/R6 rows are classified, all 15 literal paths are expanded and executed, and prose ownership claims that competed with the ledger are removed. |
| R7-H21 | **Fixed:** T9 runs `compile uiproof`, and the executed phase census proves compile precedes uiproof. |
| R7-H22 | **Fixed:** S04 drives the automatic disconnect-policy seam and reds when `onDisconnect` always returns `.stayDown`; manual reconnect is separate. |
| R7-M14 | **Fixed without answering:** Nick's verbatim packet restores the binding quote, Answer A's maximal-coverage benefit, and Answer B's no-ambient consequence. |
| R7-M15 | **Fixed:** T4 asserts rather than implements S04 capabilities; parsed-ledger strip falsification makes S04 dependencies red. |
| R7-L16/L17/L18 | **Fixed:** canImport anchors are exact, reviewer greens are the baseline, and executable rows are parsed from `plan.md`. |
| R8-H23 | **Fixed:** T4 chooses the injectable central/peripheral protocol seam, corrects the bind/connect chain, and gives S04 a discriminating arm-level mutation. |
| R8-H24 | **Fixed:** P01/P02 restore both carry-forward scenarios; the census admits exactly their allow-list and ledger labels match M1/M2/L1. |
| R8-M16 | **Fixed:** T1/T2/T3 bodies explicitly implement reconnect, detach persistence, and resume-same-capture. |
| R8-M17 | **Fixed:** exact Then-text mappings cover all 52 spec clauses, token unions match the ledger both ways, and dependency ordering is enforced. |
| R8-L19/L20/L21 | **Fixed:** baseline lines are verbatim, both load-sensitive tests are named in T9, and engine EPERM is only a provenance footnote. |
| R9-H25 | **Fixed:** T4 wraps central, peripheral, service, and characteristic types and drives the production disconnect→discovery→streaming→same-capture chain end to end. |
| R9-M18 | **Fixed:** the capability-check quote is the exact `console.log` line. |
| R9-M19 | **Fixed:** P01 includes `capture-integrity`, supplied by declared dependency T4. |
| R9-M20 | **Fixed:** T5 owns the explicit registry-order interpretation artifact used by S05. |
| R9-M21 | **Fixed at R13 base:** the reconnect arm is `:885-895`, with bind/connect at `:893-894`; both discriminating mutations name live code. |
| R9-L22 | **Fixed:** a runnable plan-time verifier smoke block and drop-token red are pasted; T0 owns the full exact-text Swift verifier. |
| R9-L23/L24/L25 | **Fixed:** T1 prose names consuming owners, P01 anchors `CaptureLiveActivityController.swift:85-89`, and P02 is transition-cause scoped. |
| R10-H26 | **Fixed:** T8 extracts the notification decision into FoundryXKit, names `FoundryXBrineTests` as the executing target, and runs both zero-post and authorized-announcement controls. |
| R10-M22 | **Fixed:** T4's refactor surface includes restoredPeripheral, both restoration/state delegate methods, and the restoration helper. |
| R10-L26/L27/L28 | **Fixed:** the wrong-owner paste is marked trimmed; 52/17 are asserted; the token mutation edits a plan artifact copy and runs the unmodified checker. |
| R11-H27 | **Fixed:** all four T8 legs name production seams and executing targets; agent dispatch is extracted from `AmbientCardBroker.run` into a Kit decision with zero, authorized, and cause-complete controls. |
| R11-M23 | **Fixed:** T8 owns the account-isolation source-text test migration to the new Kit seam, and T9 names it as expected-to-change. |
| R11-M24 | **Fixed:** Live Activity and widget controls, including P01's located mutation, run under `compile iosbrine`; macOS SwiftPM is not credited for iOS-only bodies. |
| R11-M25 | **Fixed:** the extraction owns `post`, `postPreview`, and `deliver`; the Kit decision returns a dismissal effect for the thin App adapter to apply. |
| R11-L29/L30 | **Fixed:** T8's production-leg census floor is four, and the scenario census aborts on duplicate ledger names before printing its unique count. |
| R12-H28 | **Fixed:** every retained citation is re-derived at pinned `8dc73ccd`; S04 mutations now name `:893-894` and `:931`, and the base-move law is explicit in §0. |
| R12-H29/M27 | **Fixed:** authorization remains in the shared cause-bearing Kit decision; `AmbientCardBroker.run` is only an effect applier, while movable Foundation-only outcome writing supplies the durable observable. |
| R12-M26 | **Fixed:** the old 1030-test green is labeled `296db27` provenance; T0 first establishes the actual `8dc73ccd` baseline and the gate model includes four uiproof methods plus the keychain lane. |
| R12-L31 | **Fixed by owned verifier:** the Swift both-directions union check owns class-wide column deletion; the smoke pair is explicitly historical only. |

No prior finding is deferred. NICK-DECISION-ROUTE-PRIMARY remains open, and T10-A/T10-B preserve the praised mutual exclusivity.

| Disposition class | Findings | Owner |
|---|---|---|
| fixed | Carry-forward M1/M2/L1; R1-H1/H2/M1–M3/L2; R2-H3/H4/M4–M6/L6; R3-H5/H6/M7/M8/L7–L9; R4-H7–H13/M9/M10/L10/L11; R5-H14–H17/M11/M12/L12/L13; R6-H18–H20/M13/L14/L15; R7-H21/H22/M14/M15/L16–L18; R8-H23/H24/M16/M17/L19–L21; R9-H25/M18–M21/L22–L25; R10-H26/M22/L26–L28; R11-H27/M23–M25/L29–L30; R12-H28/H29/M26/M27/L31 | T0–T9 and R13 ledger/evidence |
| mooted-by-method | R1-L1; R2-L4/L5 | Each task’s verify-before-start probe and T8 census |
| deferred | NICK-DECISION-ROUTE-PRIMARY only | Nick; then exactly one of T10-A/T10-B |
