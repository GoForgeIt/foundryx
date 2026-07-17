Feature: The app reports its own performance

  We should never learn about a slowdown only because a user forwards a hang
  report. The app measures its own launch and the heavy work it does, and it
  adopts the system's on-device performance diagnostics (hangs, launch time,
  disk, CPU, memory), and ships compact, segmentable lines to our diagnostics
  endpoint so a regression is visible across users, not one report at a time.

  Scenario: a timed span becomes one shippable perf line
    Given a perf span named "capture-hydrate" that took 820 milliseconds
    When it is reported for build "166"
    Then the line reads as a perf marker naming the span, its duration, and the build

  Scenario: a system hang diagnostic becomes a compact line
    Given a system hang diagnostic lasting 7562 milliseconds at a known call site
    When it is formatted for shipping
    Then the line names it a hang, carries the duration, and names the blamed frame

  Scenario: a launch metric becomes a compact line
    Given a system launch metric with a time-to-first-draw of 1400 milliseconds
    When it is formatted for shipping
    Then the line names the launch phase and its duration

  Scenario: every perf line carries the build and an anonymous install id
    Given any perf line
    Then it carries the app build and a stable anonymous install id
    And it never carries personal data

  Scenario: a slow span is flagged, a fast one is not
    Given the slow threshold is 500 milliseconds
    Then a 820 millisecond span is marked slow
    And a 120 millisecond span is not marked slow

  # The in-app performance overlay (track 20260717T0600 T3): a gated diagnostics
  # surface — DEFAULT OFF — so the app has a first-class, user-controllable perf
  # readout and never shows debug pills unbidden. Telemetry emission is unaffected.

  Scenario: the performance overlay is off by default
    Given a fresh install with no diagnostics preference
    Then the performance overlay is off
    And recording a perf span shows no pills

  Scenario: turning on the diagnostics toggle shows perf pills
    Given the performance overlay is turned on
    When a perf span named "capture-hydrate" of 820 milliseconds is recorded
    Then the overlay shows a pill reading "capture-hydrate 820 ms"

  Scenario: turning the overlay off stops showing pills
    Given the performance overlay is turned on
    And a perf span of 300 milliseconds has been recorded
    When the performance overlay is turned off
    Then a newly recorded perf span shows no pills

  Scenario: pills expire after their lifetime
    Given the performance overlay is turned on
    And a perf span named "lore-drain" of 120 milliseconds is recorded
    When several seconds pass
    Then the overlay shows no pills

  Scenario: the overlay keeps only the newest few pills, newest first
    Given the performance overlay is turned on
    When six perf spans are recorded
    Then the overlay shows only the newest four
    And the newest pill is first

  Scenario: telemetry ships identically whether the overlay is on or off
    Given a perf span named "capture-hydrate" that took 820 milliseconds
    Then the shipped perf line is byte-identical with the overlay off and on

  # Live main-thread stall reporting (track 20260717T0900 WS-A): the app names WHERE it
  # stalled from the user's own device — not just that it stalled — for the ~700ms nav
  # hangs MetricKit's daily hang path never surfaces. Bounded so a stuck device can't flood.

  Scenario: a sustained main-thread stall is reported with the blocked code location
    Given the main thread is blocked at a known call site for 700 milliseconds
    When the stall is captured and formatted for shipping
    Then the line names it a stall stack, carries the duration, and names the blocked frame

  Scenario: a runaway CPU burn reports its full call stack
    Given a runaway CPU exception of 90000 milliseconds with a full call tree
    When it is formatted for shipping
    Then the line names it a CPU stack and carries every frame with an image table

  Scenario: a brief stall under the threshold is not reported
    Given the stall threshold is 250 milliseconds
    And the main thread pauses for 120 milliseconds
    Then no stall is reported

  Scenario: stall reporting is bounded so a stuck device cannot flood telemetry
    Given a stall report budget of at most 1 report every 5 seconds and 60 per session
    When 3 stalls happen within the same second
    Then only 1 stall is reported
    And after the session cap is reached further stalls are dropped

  # The on-device model wedge breaker (track WS-C): a wedged Apple Foundation Models
  # turn is unblocked at the 20s deadline but keeps burning CPU in a detached task
  # (~86s measured). Without a breaker EVERY call site can spawn a fresh runaway. A
  # session-scoped breaker trips on the first wedge and refuses further turns for a
  # cool-down, so a wedged model costs one runaway — not one per call site.

  Scenario: a wedged on-device model is not called again for a cool-down
    Given a healthy on-device model breaker
    When the on-device model wedges
    Then the next on-device turn is refused for the cool-down

  Scenario: after the cool-down one probe decides, and a healthy probe restores normal turns
    Given a wedged on-device model breaker
    When the cool-down elapses
    Then exactly one on-device probe is allowed
    And a second on-device turn is still refused
    When the probe turn succeeds
    Then on-device turns proceed normally

  Scenario: after the cool-down a re-wedged probe re-opens the cool-down
    Given a wedged on-device model breaker
    When the cool-down elapses
    And the on-device probe wedges again
    Then the next on-device turn is refused for the cool-down

  Scenario: a healthy on-device model is unaffected by the breaker
    Given a healthy on-device model breaker
    Then on-device turns proceed normally
