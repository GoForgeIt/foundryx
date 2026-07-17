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
