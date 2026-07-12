Feature: Ambient intelligence is opt-in and finds actionable moments privately

  Live conversations can trigger help — "I'll have to look that up" answered from the
  user's own memory, a request addressed to their named agent — but ONLY if the user
  opted in, and everything up to a candidate happens on the phone: an on-device
  transcript accrues while recording and an on-device gate (whose default answer is
  NO) watches for actionable moments. Off means OFF: no transcript, no gate, no
  processing of any kind — capture behaves exactly as if the feature didn't exist.
  Every gate decision is logged so over-eager or dead gates are diagnosable.

  Scenario: ambient intelligence is off by default
    Given a fresh install
    Then ambient intelligence is disabled

  Scenario: disabled means zero ambient processing
    Given ambient intelligence is disabled
    And a conversation is being recorded
    When new audio arrives
    Then no ambient transcript is produced
    And no gate evaluation occurs
    And no ambient decision is recorded

  Scenario: while enabled, the live transcript window is gated on a cadence
    Given ambient intelligence is enabled
    And a conversation is being recorded
    When new speech arrives on the live transcript
    Then the gate evaluates the newest window
    And the decision is recorded

  Scenario: an unchanged window during silence is skipped for free
    Given ambient intelligence is enabled
    And the live transcript has not changed since the last check
    When the lane is asked to consider it again
    Then the gate is not called
    And no decision is recorded

  Scenario: an ordinary conversation produces no candidates
    Given ambient intelligence is enabled
    And the conversation contains no actionable moments
    When several minutes of speech are processed
    Then every window is gated NO
    And no candidate is surfaced

  Scenario: an actionable moment becomes a candidate
    Given ambient intelligence is enabled
    When the conversation contains "I'll have to look up what we decided about the relay"
    Then the gate surfaces a candidate for that utterance
    And the candidate is recorded with its confidence

  Scenario: a busy or failing engine skips silently
    Given ambient intelligence is enabled
    And the on-device engine is unavailable
    When new audio arrives
    Then the window is skipped
    And the skip is recorded
    And recording itself is unaffected
