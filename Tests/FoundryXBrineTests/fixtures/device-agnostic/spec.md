# Track: device_agnostic_recording_source

- **Parent proposal:** `20260722T2025_operating_graph_foundryx_lane`
- **Sibling retained:** `20260722T2030_ambient_restore_coordination` owns door relaunch and shipping.
- **Revision:** R6 — the R5 scope-disciplined behavioral rewrite plus a surgical revision addressing the review
  of that rewrite. **Review record:** the review of spec rev 1 is in `spec.review.rev1.md`; the reviews of spec
  revs 2–5 and of the R5 rewrite are in `spec.review.md`. In §7, `rev N` always names *the review of spec rev N*,
  never spec rev N itself.

No delivery timelines are specified. The three-minute values below are runtime behavior bounds.

## 1. Intent and outcome

Nick's correction is binding:

> "for the device, this should just be one thing to connect, we shouldn't hyper focus on omi, it could be any
> external bluetooth recording device"

This track makes eligibility capability-based rather than vendor- or model-based. Any external Bluetooth
recording device the handset can use for valid capture can be connected. Omi is the first proving instance,
never the design centre and never a privileged branch.

The user gets one affordance and one list, without first classifying the device. Liveness becomes visible at the
real FoundryX and ambient-status surfaces. Agents still act only on a registered playbook match or `@`-mention.

## 2. Behavioral requirements

### R1 — Device-agnostic capture

- Vendor or model identity must never determine whether an otherwise usable external Bluetooth recorder can
  connect, become active, record, and finalize a conversation.
- The same behavior must hold for an Omi-shaped BLE stream, a non-Omi BLE stream, and a Bluetooth audio-route
  device. *(The audio-route arm's always-on ambient role is conditional on the open human decision in §6 and is
  not settled by this spec.)*
- A device that cannot supply usable audio must be refused explicitly before unusable data becomes a completed
  or corrupt capture. A later loss of usable audio must fail visibly and preserve already-valid audio.

### R2 — One thing to connect

- The rendered app has exactly one recording-device connection affordance.
- That affordance leads directly to one list containing every currently discovered eligible device.
- The user is never required to choose a vendor, transport, or device family before seeing the device.
- Sorting, labels, and per-device capability badges are allowed. A filter, default, or collapsed group must not
  hide a device because of its family.
- Generic copy is brand-free; copy about a selected device uses that device's reported name.

### R3 — Honest capability and failure surfaces

- A capability the device does not provide is shown as unavailable, never as a plausible default.
- A capability the app does not understand may remain unavailable; it must not crash discovery or create a
  vendor branch.
- If audio lost during a disconnect cannot be recovered, the user is told that it was not recoverable.
- Stale, disconnected, no device, and devices remembered but none active are each distinguishable from one
  another, without qualification. A known capture refusal is shown.

### R4 — Reconnect, substitution, and multiple devices

- A system-caused drop retries and reconnects without requiring the user to reopen the app. A user detach stays
  detached.
- A short reconnect resumes the in-flight conversation; a long gap follows the existing conversation-boundary
  behavior.
- More than one device can be remembered across relaunch, but at most one is active. When at least one
  remembered device is armed and ready, one is active.
- User preference and current readiness choose the active device; vendor identity never wins a priority tie.
- Replacing the active device with another eligible device, including one with a different connection shape,
  succeeds through the same connection experience and preserves capture continuity and source attribution.
  *(Substitution into the always-on ambient role by a device of a different connection shape is conditional on
  the open human decision in §6.)*

### R5 — Persistence, migration, and attribution

- Pairing state is account-scoped. A second account on the handset cannot see or activate the first account's
  devices.
- A device paired before this track survives upgrade without a physical re-pair. If no account is available at
  upgrade, it is retained without being assigned to an arbitrary account and is restored after sign-in.
- New recordings identify the device that produced them without making legacy Omi or microphone recordings
  unreadable.
- Users whose history contains only recordings made after this change are not re-onboarded; legacy-only users
  remain unaffected.

### R6 — Bounded, recoverable liveness

- When the active device loses its link, the rendered FoundryX device surface and the ambient-status surface
  show **disconnected**, with last-heard age, within three minutes.
- When the active device remains attached but stops delivering usable audio, both surfaces show **stale**, with
  last-heard age, within three minutes.
- An active device that has **not yet delivered usable audio since attaching** is not healthy at either surface,
  for as long as that remains true; its last-heard age runs from the attach. Attachment, presence, or any other
  positive observation that is not usable audio must never render healthy, under any freshness accounting the
  plan chooses.
- Missing or invalid liveness evidence must never render healthy. Later verified source activity restores a
  healthy state within three minutes; one malformed observation must not make the status permanently red.
- A remembered idle device becoming healthy or unhealthy cannot mask, green, or falsely redden the active
  device.
- Forgetting one of several devices leaves the active device's status correct. Forgetting the last device
  shows **no device** within three minutes. Unarming the only active device while retaining it shows
  **none active** within three minutes.
- The bounds are measured at the observing surfaces by Brine elapsed time, independent of the eventual clock,
  event, storage, or transport representation.

### R7 — Device-status privacy

- If device status crosses the handset boundary, the real outbound handoff and ambient-status observations
  expose neither the user-authored display name nor a raw hardware identifier or diagnostic free text.
- Status for one account must not provide a stable cross-account device correlation.

### R8 — Ambient silence, at every surface that speaks unprompted

- Device discovery, attach, detach, failure, stale, recovery, hand-off, forget, and no-device transitions alone
  cause **zero agent actions** at the production agent-dispatch seam.
- Those same transitions alone also cause **zero unprompted user-facing announcements** at the real seams that
  post them: no local notification, no lock-screen or Dynamic Island Live Activity created, updated, or alerted
  on account of a device or liveness transition, and no widget announcement of device or liveness state. This
  obligation binds at the surface that actually posts, not only at the agent-dispatch seam.
- Device and liveness state may be rendered in a surface the user opened. A capture rendering the user already
  started may continue to show capture state; a device or liveness transition alone must not create it, expand
  it, or make it alert.
- Every agent action at that seam has a contemporaneous registered playbook match or explicit `@`-mention; no
  other ambient input qualifies.
- A registered playbook match may cause only the action registered for that match.
- An explicit `@`-mention may cause the mentioned agent to act.
- Rendering device state in the user-opened device or ambient-status surface is not an agent action.

## 3. Acceptance: executable Brine/Gherkin outlines

These scenarios drive rendered production surfaces, discovery, capture/finalize, account persistence, ambient
status, and agent dispatch. Fixtures may replace radios, devices, accounts, time, and remote availability, but
not the production unit at an asserted seam.

Every scenario below must be demonstrated **red against the current tree** before the implementation that greens
it, and the plan must name, for each requirement, the change that turns that requirement's scenario red. A
scenario that has never been observed failing is not accepted as proof of the requirement it carries.

```gherkin
Feature: Connect any eligible external Bluetooth recording device
  Scenario Outline: each device shape connects through the one experience
    Given the app is signed in and has no recording device
    And an eligible "<shape>" device named "<name>" is discoverable
    And eligible devices of the other shapes are discoverable
    Then the rendered app has exactly one recording-device connection affordance
    When I open that affordance
    Then all devices are visible together without a vendor or family choice
    And no reachable list control hides any device by family
    When I connect "<name>" and record a conversation
    Then the production capture path finalizes the conversation
    And the timeline attributes it to "<name>"
    And generic device copy names no vendor
    # The "Bluetooth audio route" row's always-on ambient-role content is conditional on the §6 human decision.
    Examples:
      | shape                  | name             |
      | Bluetooth audio route  | Field Recorder   |
      | Non-Omi BLE stream     | Trail Mic        |
      | Omi-shaped BLE stream  | Omi               |
  Scenario Outline: unusable audio is refused without corrupting capture
    Given a discoverable external Bluetooth device has "<history>"
    When it supplies unusable audio "<phase>"
    Then the device is refused with an actionable reason
    And no unusable audio is persisted
    And any previously valid audio finalizes normally
    And other eligible devices remain available to connect
    Examples:
      | phase                 | history               |
      | at connection         | delivered no audio    |
      | after capture begins  | delivered valid audio |
  Scenario: absent capabilities are not invented
    Given a connected device declares no firmware value and no gap recovery
    Then the device surface shows both capabilities as unavailable
    And it shows no fabricated firmware value
    When the device disconnects and audio from the gap cannot be recovered
    Then the surface says that the gap audio was not recoverable
```

```gherkin
Feature: Recording-device continuity and ownership
  Scenario: system reconnect preserves continuity while user detach stays detached
    Given an active external recording device is capturing a conversation
    When the system link drops and returns inside the existing short-gap boundary
    Then the device reconnects without reopening the app
    And capture resumes the same conversation
    When I explicitly detach the device
    Then it remains detached until I reconnect it
  Scenario: another device substitutes without vendor priority
    Given two differently shaped devices are remembered across relaunch and both are ready
    And device A is the shape the shipped source ordering ranks last and device B is the shape it ranks first
    And device A is active because I selected it
    Then device A stays active while both devices are ready
    When device A becomes unready
    Then at most one device remains active
    And any hand-off follows preference and readiness rather than vendor identity
    When I select device B and record
    Then new audio is attributed to device B
    And archived audio remains attributed to device A
  Scenario: legacy pairing and history survive an account-scoped upgrade
    Given a legacy Omi pairing and legacy recordings exist before upgrade
    When the signed-in account launches the upgraded app
    Then the device remains paired and active without a physical re-pair
    And the legacy history remains visible without onboarding
    When a second account signs in on the same handset
    Then it cannot see or activate the first account's device
  Scenario: device-agnostic history does not trigger onboarding
    Given an account's history contains only recordings made after device-agnostic source support
    When that account launches the upgraded app
    Then its recording history remains visible
    And device onboarding does not run
  Scenario: signed-out upgrade does not leak or discard legacy pairing
    Given a legacy device is paired and no account is signed in during upgrade
    Then the device is retained without assignment to an account
    When its owner signs in
    Then the device is restored without a physical re-pair
```

```gherkin
Feature: Recording-device liveness at real surfaces
  Scenario Outline: active-device failure is visible within the bound
    Given an active device is healthy at the production capture seam
    When "<condition>" occurs
    Then within three minutes the FoundryX device surface shows "<state>"
    And within three minutes the ambient-status surface shows "<state>"
    And both surfaces show how long since usable audio was last heard
    Examples:
      | condition                         | state         |
      | its link is lost                  | disconnected  |
      | it stops delivering usable audio  | stale         |
  Scenario: a device that has never delivered usable audio is never healthy
    Given an active device attaches at the production capture seam
    And it has never delivered usable audio since attaching
    Then neither status surface shows healthy for as long as that remains true
    And within three minutes both status surfaces show stale
    And the last-heard age both surfaces show runs from that attach
    When the device delivers verified usable audio for the first time
    Then both status surfaces show healthy within three minutes
  Scenario: an idle remembered device cannot answer for the active device
    Given device A is active and healthy
    And device B is remembered, idle, and healthy
    When device B disconnects
    Then device A remains healthy at both status surfaces
    When device B becomes healthy and device A stops delivering usable audio
    Then both status surfaces report device A stale within three minutes
    When device A resumes verified audio and I forget device B
    Then device A remains active and healthy at both status surfaces
  Scenario: no device and no active device remain distinct
    Given the only active device is unarmed but remains remembered
    Then within three minutes both status surfaces show devices remembered but none active
    When I forget the last remembered device
    Then within three minutes both status surfaces show no device
  Scenario: later valid activity recovers from bad status evidence
    Given the active device's current liveness evidence is invalid
    Then neither status surface shows healthy
    When the active device again delivers verified usable audio
    Then both status surfaces show healthy within three minutes
```

```gherkin
Feature: Device status respects privacy and ambient silence
  Scenario: personal device identity does not cross the handset boundary
    Given my device is named "Sarah's AirPods Pro"
    When its status reaches the production ambient-status handoff
    Then the outbound observation contains no display name
    And it contains no raw hardware identifier or diagnostic free text
    And another account cannot correlate the device to its own device status
  Scenario Outline: a device transition alone makes nothing speak unprompted
    Given no registered playbook matches and nobody has mentioned an agent
    And no device or status surface is open
    When the active device becomes "<state>"
    Then the production agent-dispatch seam receives zero agent actions
    And the production notification-posting seam receives zero posts
    And the production live-activity seam receives no creation, update, or alert for that transition
    And no widget announcement of device or liveness state is emitted
    Examples:
      | state         |
      | connected     |
      | disconnected  |
      | stale         |
      | recovered     |
      | forgotten     |
      | none active   |
  Scenario Outline: only an allowed ambient trigger causes agent action
    Given the device state changes
    When "<trigger>" occurs
    Then the production agent-dispatch seam receives only "<action>"
    Examples:
      | trigger                         | action                    |
      | a registered playbook matches  | the registered action     |
      | I explicitly @-mention Agent A  | Agent A's mentioned action |
  Scenario: every emitted agent action has an allowed cause
    Given ambient input includes registered matches, explicit @-mentions, and unrelated events
    When the production agent-dispatch seam processes that input
    Then every emitted action is caused by a registered playbook match or explicit @-mention
    And no unrelated event emits an agent action
```

## 4. Named plan-phase decisions

Each unresolved mechanism is chosen at plan against real code and must satisfy the linked requirements and
Brine scenarios.

- **PD-SOURCE-INTEGRATION** — choose discovery, source integration, audio adaptation, and unusable-audio
  refusal. Must satisfy R1, R3, and R4. Candidate approaches noted: adapt handset audio routes; describe BLE
  stream profiles as data; extend the existing capture-source registry; combine those behind an existing seam.
- **PD-CONNECT-UX** — choose how actual discovery results reach the one rendered affordance and one visible
  device set. Must satisfy R2. Candidate approaches noted: merge discovery results in the current registry;
  compose them at the current device-list presenter.
- **PD-DEVICE-STATE** — choose account-scoped storage, active selection, legacy migration, and signed-out hold.
  Must satisfy R4 and R5. Candidate approaches noted: the account-scoped pairing/preference seams from sibling
  tracks; an adapter over the current stores until those seams land.
- **PD-ARCHIVE-IDENTITY** — choose source attribution and migration against every real capture-history reader.
  Must satisfy R4, R5, and R7. Candidate approaches noted: an explicit source record beside capture metadata;
  an additive reader migration that preserves legacy identifiers.
- **PD-LIVENESS** — choose the real phone-to-ambient status seam, authoritative clock, bounded freshness
  accounting, malformed-input recovery, privacy representation, and repository boundary. Must satisfy R3, R6,
  and R7. Candidate approaches noted: reuse an existing status channel; add a narrow liveness event; derive
  freshness from receiver-controlled receipt time; use an existing run-status surface. No endpoint, record
  schema, heartbeat, counter, clock formula, file, or evaluator algorithm is selected by this spec.
- **PD-AMBIENT-SILENCE-PROOF** — choose the real gate at which playbook matches and `@`-mentions authorize agent
  action, and the real production seams through which notifications, Live Activities, and widget updates are
  posted, at which R8's unprompted-announcement prohibition is asserted. Must satisfy R8. Candidate approaches noted: assert at the ambient gate output; assert at the agent
  dispatch boundary. No notification sink, Live Activity seam, source scan, import allowlist, caller census, or
  control-versus-treatment byte comparison is selected by this spec.

## 5. Honest scope

- This track supports handset-usable external Bluetooth recording devices by capability; it does not publish a
  model compatibility matrix or certify every third-party product.
- It preserves one active source and the existing conversation-boundary behavior. Multi-source mixing is out.
- Door relaunch/shipping and B4's downstream measure consumption remain with their existing tracks.
- Android, a watchOS capture app, and changes above the agent-action authorization seam are out.
- Exact codec framing, adapter interfaces, persistence schemas, endpoint/file formats, clocks, freshness
  accounting, and registration sequencing are plan decisions, not spec requirements. Notification, Live Activity,
  and widget behavior remain outside this track **except** for R8's prohibition on unprompted announcement of a
  device or liveness transition, which is in scope and asserted at the seams that post.
- Physically attaching an eligible device and enabling ambient capture remain user actions.

## 6. Open human decision — NICK-DECISION-ROUTE-PRIMARY

**Status: OPEN. This is Nick's to answer and no agent's to resolve.** Five consecutive independent reviews
recorded it as an open human gate. The R5 rewrite deleted it and recorded *"Nick's universal intent governs"*;
that closure was **invalid** — an agent resolved a human gate — and it is reversed here (see the `rev1 M6` row in
§7). No answer is proposed and no default is chosen below.

**The question.** May a route-backed device — a Bluetooth audio-route input, e.g. an HFP headset — be the
**primary, always-on ambient sensor**? Or is a route-backed device eligible to connect and record while the
always-on ambient role requires a stream-backed device?

**Why the binding quote does not answer it.** *"it could be any external bluetooth recording device"* settles
**eligibility to connect**, which R1 and R2 make universal and which is not in question. It does not settle
whether such a device may hold the always-on ambient role. On iOS a Bluetooth audio-route input is commonly
8/16 kHz and occupies the shared audio route for the whole handset while active. That is a product trade —
coverage against fidelity and against what else the handset can do — with consequences Nick owns.

**Answer A — yes, a route-backed device may be the primary ambient sensor.**
Consequences: the requirement text stands exactly as written; R1's audio-route arm, R4's different-shape
substitution, and Feature 1's `Bluetooth audio route` row all assert the always-on role; coverage is maximal
(any headset the user already owns works as the ambient sensor); the handset's shared audio route may be held
at HFP quality for long ambient sessions, and ambient audio fidelity for route-backed devices is whatever the
route delivers.

**Answer B — no; route-backed devices connect and record, but the always-on ambient role requires a
stream-backed device.**
Consequences: R1's audio-route arm narrows to user-initiated capture; R4's different-shape substitution excludes
substitution *into* the ambient role; Feature 1's `Bluetooth audio route` row asserts connect/record/finalize but
not the ambient role, and a companion assertion is required that the ambient role **declines a route-backed
device visibly, with an actionable reason** — never silently. R3's honest-surfaces requirement then covers that
refusal, and R6's liveness surfaces must distinguish "not eligible for the ambient role" from "stale".

**Content conditional on this decision** (nothing else in the spec is):

| Location | Conditional content |
|---|---|
| R1, bullet 2 | the audio-route arm's always-on ambient role |
| R4, bullet 5 | substitution into the ambient role by a device of a different connection shape |
| §3, Feature 1, Examples row `Bluetooth audio route \| Field Recorder` | whether that row's capture is the always-on ambient role or user-initiated capture only |

The plan phase must not begin on the conditional content until Nick answers, and must not read the drafting
posture of the surrounding text as the answer.

## 7. Prior-review disposition

The table covers all 55 formal findings across six review rounds. `Fixed` means a behavioral requirement and
real-seam scenario now close it. `Mooted-by-deletion` names machinery removed from the spec. `Descoped` names a
finding whose risk is deliberately left unbound, with the consequence stated. `Deferred-to-plan` names the
decision that must be made against current code. `Reversed` names a prior disposition withdrawn as invalid.
`rev N` names *the review of spec rev N*; `revR5` names the review of the R5 rewrite (the round this revision
answers).

| Round / finding | Disposition | R5 treatment |
|---|---|---|
| rev1 C1 | Deferred-to-plan | PD-LIVENESS chooses any cross-boundary seam and repository scope; R6/R7 constrain it. |
| rev1 H1 | Fixed | R6 is proved at this track's real FoundryX and ambient-status seams, not in B4. |
| rev1 H2 | Fixed | R7 proves personal device identity absent at the outbound seam. |
| rev1 H3 | Deferred-to-plan | PD-SOURCE-INTEGRATION chooses conversion/refusal; R1 proves both acceptance and safe refusal. |
| rev1 H4 | Fixed | The R1 outline originates end-to-end from audio-route, non-Omi stream, and Omi-shaped devices. |
| rev1 M1 | Deferred-to-plan | PD-SOURCE-INTEGRATION chooses the real source seam; the pseudo-Swift protocol was deleted. |
| rev1 M2 | Fixed | R4 proves a remembered set, at most one active device, and no vendor priority — and the substitution scenario now pins the discriminating fixture (both devices ready, the user-preferred device is the one the shipped ordering ranks last), so the vendor ladder cannot survive it. |
| rev1 M3 | Fixed | R5 proves account isolation at the real session/store seam. |
| rev1 M4 | Fixed | R5 proves legacy and new histories remain readable without onboarding. |
| rev1 M5 | Fixed | R3/R4 directly prove reconnect and honestly absent gap recovery; parity accounting was deleted. |
| rev1 M6 | **Reversed** | The R5 rewrite's closure — *"the route-primary gate and conditional AC table were deleted; Nick's universal intent governs"* — was **invalid**: it resolved an open human gate on Nick's behalf from a quote about eligibility, and it made the negative answer unrepresentable rather than conditional. The gate is restored in §6 as an explicit open human decision with both answers' consequences and the three conditional locations named. rev1 M6's original request (state which acceptance is conditional on the gate, and what it becomes under each answer) is thereby **Fixed**. |
| rev1 L1 | Fixed | The per-AC mutation catalogue stays deleted, but §3 now carries the obligation it existed to carry: every scenario is demonstrated red against the current tree before the implementation that greens it, and the plan names the change that reddens each requirement's scenario. |
| rev1 L2 | Fixed | R3 makes capability reporting open and honest without a closed enumeration. |
| rev1 L3 | Fixed | R2 proves copy at the rendered surfaces without prescribing a presentation function. |
| rev2 H1 | Deferred-to-plan | PD-LIVENESS owns accounting; R6 proves active-device truth in a multi-device world. |
| rev2 H2 | Fixed | R2 and the first feature prove one affordance and one visible device set. |
| rev2 H3 | Fixed | R8 now binds at **both** seams: negative and positive authorization at the real agent-dispatch seam, **and** zero unprompted notification / Live Activity / widget announcement of a device or liveness transition at the real posting seams. H3's constructed failure — a notification posted on a liveness transition — is red on the transition outline. |
| rev2 H4 | Deferred-to-plan | PD-SOURCE-INTEGRATION replaces the unstateable packet predicate; R1 proves outcomes. |
| rev2 M1 | Mooted-by-deletion | The bespoke shipper, watermark, and 404 protocol were deleted. |
| rev2 M2 | Mooted-by-deletion | The `none_paired` wire schema and sentinel problem were deleted. |
| rev2 M3 | Deferred-to-plan | PD-LIVENESS chooses clock/accounting; R6 fixes the three-minute observable bound and age. |
| rev2 M4 | Fixed | R7 and R5 prove privacy and account separation; the SHA/salt recipe was deleted. |
| rev2 M5 | Deferred-to-plan | PD-LIVENESS identifies the real repositories after choosing the status seam. |
| rev2 M6 | Fixed | R5 proves existing pairing survives upgrade without a re-pair or account leak. |
| rev2 L1 | Deferred-to-plan | PD-SOURCE-INTEGRATION and PD-ARCHIVE-IDENTITY resolve the current registry and identifiers. |
| rev2 L2 | Mooted-by-deletion | The 5-of-9 parity count and vacuous-arm machinery were deleted. |
| rev2 L3 | Mooted-by-deletion | Threshold override and absent-seam configuration machinery were deleted; R6 is unconditional. |
| rev3 N1 | Deferred-to-plan | PD-DEVICE-STATE/PD-LIVENESS choose accounting; R6 proves the none-active result. |
| rev3 N2 | Mooted-by-deletion | Notifier counters, import scans, and OS-boundary instrumentation were deleted. |
| rev3 N3 | Deferred-to-plan | PD-SOURCE-INTEGRATION chooses ongoing validation; R1 requires visible safe failure. |
| rev3 N4 | Fixed | R2 forbids family classification before or inside the device list. |
| rev3 N5 | Deferred-to-plan | PD-LIVENESS chooses time authority; R6 proves elapsed behavior without `silent_for_ms`. |
| rev3 N6 | Mooted-by-deletion | The closed link-to-return-variant mapping, including its unmapped attaching/failed states, was deleted. |
| rev3 N7 | Mooted-by-deletion | Cross-repository mutation bookkeeping and the fixed wire mechanism were deleted. |
| rev4 R1 | Deferred-to-plan (accounting) + Fixed (never-heard case) | PD-LIVENESS still chooses freshness accounting, but R6 now forbids healthy for a device that has not delivered usable audio since attaching — under **any** anchor the plan picks — and the never-delivered scenario asserts it. |
| rev4 R2 | Mooted-by-deletion (machinery) + Fixed (risk) | The destination/capability allowlist and Live Activity expansion counters stay deleted; the risk they were built for — a second speaking capability living on the liveness module's own layer — is now bound behaviorally by R8's unprompted-announcement clause and asserted at the posting seams. |
| rev4 R3 | Mooted-by-deletion | All `UN…` and import-source scan invariants were deleted. |
| rev4 R4 | Fixed | R2 asserts set visibility under every reachable list state while allowing sorting. |
| rev4 R5 | Deferred-to-plan | PD-DEVICE-STATE/PD-LIVENESS choose departure accounting; R6 proves both forget outcomes. |
| rev4 R6 | Mooted-by-deletion | Mutation exclusivity bookkeeping was deleted. |
| rev4 R7 | Mooted-by-deletion | Implementation line citations and the machinery they supported were deleted. |
| rev5 H1 | Mooted-by-deletion (machinery) + Fixed (risk) | `LiveSurfaceSink`, funnel claims, and caller-set machinery stay deleted. The failure H1 constructed — a live surface driven around the funnel, on a liveness transition — is caught by R8's outcome-level prohibition, which binds at the surface that posts regardless of the path taken to reach it. |
| rev5 H2 | Mooted-by-deletion | Byte-identical control/treatment comparison and normalization machinery were deleted. |
| rev5 M1 | Fixed | R6 and the link-loss scenario require an ordinary drop to render disconnected; the contradictory reason-field validator and wire schema were deleted. |
| rev5 M2 | Fixed | R6 and the recovery scenario require later valid activity to restore health; the JSONL parser and absorbing `Invalid` algorithm were deleted. |
| rev5 M3 | Deferred-to-plan | PD-LIVENESS owns clock authority/skew while R6 fixes the observed bound. |
| rev5 L1 | Fixed | R2 asserts device-set visibility, not sequence identity, so sorting remains valid. |
| rev5 L2 | Fixed | R6 and the no-device scenario require the state within three minutes; the `none_paired` record-kind schema was deleted. |
| revR5 H1 | Fixed | §6 restores the route-primary decision as an explicit OPEN human gate — both answers, their consequences, and the three conditional locations — and §7's `rev1 M6` row records the prior agent closure as invalid. Nothing is resolved and no default is chosen. |
| revR5 M1 | Fixed | R6 gains the never-heard-since-attach clause (attachment or presence never renders healthy; last-heard age runs from the attach) and Feature 3 gains the never-delivered scenario, red under any plan-chosen anchor. |
| revR5 M2 | Fixed | R8 now binds the unprompted-announcement prohibition at the seams that actually post (notification, Live Activity, widget), the transition outline asserts zero posts there, §5's blanket descope is narrowed to everything *except* that prohibition, and `rev2 H3` / `rev4 R2` / `rev5 H1` are relabelled accordingly. The trade the descope would have made is therefore not made. |
| revR5 M3 | Fixed | The substitution scenario pins the discriminating fixture: both devices remembered and ready, the user-preferred device is the one the shipped ordering ranks last, that device is active, and it must stay active while both are ready. Red on the shipped `case .omi: return 0` ladder. |
| revR5 M4 | Fixed | §3 now obliges every scenario to be shown red against the current tree before the implementation that greens it, and obliges the plan to name the reddening change per requirement. |
| revR5 L1 | Fixed | R3's *"wherever remediation differs"* qualifier is dropped; the four states are distinguishable without qualification. |
| revR5 L2 | Fixed | This revision is labelled R6, and the header states that `rev N` always names the review of spec rev N. The review of the R5 rewrite is labelled `revR5` in this table. |

Surgical revision role only — this pass addressed the named findings and recorded no verdict. Independent review
records the verdict.
