Feature: Audio missed during a link gap is reported truthfully

  Track 20260725T2306_device_agnostic_recording_source, task T3. When the link returns, a
  gap-recovery window opens BEFORE service discovery so recovered audio cannot arrive after
  live audio. Every close of that window is modelled as DATA, so no call site can invent an
  outcome and no path can publish two.

  The distinction the user actually cares about: audio the device STILL HOLDS for the next
  reconnect is not lost, and must never be reported as unrecoverable. Only audio that is
  genuinely gone is.

  A window is tagged AT OPEN with the conversation the drop interrupted — a fact
  `CaptureManager` owns, never one `DeviceManager` infers — and a window that interrupted
  nothing says nothing at all.

  Scenario: a drop before service discovery keeps the span for the next reconnect
    Given a conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When the link drops again before the sync engine starts
    Then the outcome says the audio is still on the device
    And the outcome is not a loss
    When the device reconnects and the same span is pulled back
    Then the outcome reports the audio as recovered
    And no outcome anywhere in this scenario claimed the audio was unrecoverable

  Scenario: the decision deadline passes without the storage service appearing
    Given a conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When the storage service never appears and the decision deadline passes
    Then the outcome says the audio is still on the device
    And the outcome is not a loss

  Scenario: a device that keeps no audio while disconnected is reported honestly as a loss
    Given a conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When the device turns out to have no offline storage at all
    Then the outcome reads "unrecoverable"
    And the outcome is a loss only when the audio is really gone

  Scenario: stored audio that cannot be reached this time is not a loss
    Given a conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When the device's stored audio cannot be reached this time
    Then the outcome says the audio is still on the device
    And the outcome is not a loss

  Scenario: a window that interrupted no conversation closes silently
    Given no conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When the link drops again before the sync engine starts
    Then no outcome is published at all

  Scenario Outline: every engine ending is reported for what it is
    Given a conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When the sync engine ends with "<ending>"
    Then the outcome reads "<outcome>"
    And the outcome is a loss only when the audio is really gone
    Examples:
      | ending               | outcome              |
      | nothing to sync      | nothing buffered     |
      | a full transfer      | recovered            |
      | a transfer with no frames | nothing buffered |
      | a partial transfer   | partially recovered  |
      | a failure            | still on the device  |
      | a dropped link       | still on the device  |
      | unsupported firmware | unrecoverable        |

  Scenario: one opened window publishes at most one outcome
    Given a conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When the window is closed twice
    Then exactly one outcome is published

  Scenario: the interrupted conversation is resumed, never replaced
    Given a conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    Then the window still carries that conversation identity
    When nothing proposes a different conversation
    Then the original conversation is resumed
    When a replacement conversation is proposed
    Then the replacement is refused and the original identity is kept

  Scenario: a window that interrupted nothing opens a fresh conversation
    Given no conversation was interrupted when the link dropped
    And the device reconnects and the gap window opens
    When nothing proposes a different conversation
    Then a fresh conversation is opened
