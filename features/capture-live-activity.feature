Feature: The capture Live Activity distinguishes recording, paused, and listening

  The Live Activity (Dynamic Island + lock screen) must reflect REAL capture activity,
  not merely that the source is armed. It shows a running elapsed timer and a live
  "capturing" indicator ONLY while voiced audio is actively being captured. While paused
  it shows a paused state (no running timer, no "conversation in progress"), and during an
  extended silence while the device stays connected it shows LISTENING (idle) — never a
  live conversation with a ticking clock. It also offers two interactive buttons.

  Scenario: actively capturing voice shows the RECORDING-ACTIVE phase with a live timer
    Given an ambient capture is recording a conversation
    And voiced audio is arriving
    Then the Live Activity phase is recording-active
    And the Live Activity shows a running elapsed timer

  Scenario: pausing capture shows the PAUSED phase and stops the elapsed timer
    Given an ambient capture is recording a conversation
    When I pause capture
    Then the Live Activity phase is paused
    And the Live Activity shows no running elapsed timer

  Scenario: an extended silence while armed shows LISTENING, not a live conversation
    Given an ambient capture is recording a conversation
    And no voiced audio has arrived for longer than the active-voice window
    Then the Live Activity phase is idle
    And the Live Activity shows no running elapsed timer

  Scenario: resuming capture returns to LISTENING until voice resumes
    Given a paused ambient capture
    When I resume capture
    Then the Live Activity phase is idle
    When voiced audio arrives
    Then the Live Activity phase is recording-active

  Scenario: the live transcript appears on the Live Activity while actively recording
    Given an ambient capture is recording a conversation
    And a live transcript line is available
    Then the Live Activity shows the latest transcript line truncated for the small surface

  Scenario: the coarse level bar reflects the current voice level while recording
    Given an ambient capture is recording a conversation
    And loud voiced audio is arriving
    Then the Live Activity coarse level shows more lit bars than during quiet audio

  Scenario: the End Current button finalizes the current conversation and starts a new one
    Given an ambient capture is recording a conversation
    When I tap the End Current button on the Live Activity
    Then the current conversation is finalized and sent for transcription
    And a new conversation begins recording immediately without dropping audio

  Scenario: the End Current button does nothing when no conversation is active
    Given nothing is being captured
    When I tap the End Current button on the Live Activity
    Then no conversation is finalized

  Scenario: the Pause/Resume button toggles capture pause
    Given an ambient capture is recording a conversation
    When I tap the Pause button on the Live Activity
    Then capture is paused
    When I tap the Resume button on the Live Activity
    Then capture is resumed

  Scenario: the Live Activity update cadence is throttled and coalesced
    Given an ambient capture is recording a conversation
    When the meaningful capture state has not changed
    Then a throttled Live Activity update is coalesced away
