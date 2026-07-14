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
