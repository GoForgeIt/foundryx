Feature: Phone-mic recording survives interruptions

  The whole promise of the app is to reliably save what you record. A phone call,
  a Siri invocation, a Bluetooth route change, or the audio system resetting must
  NOT silently kill an in-progress phone-mic recording. Audio captured before the
  interruption is durable, and capture resumes automatically when the interruption
  ends — the conversation continues as one recording.

  Scenario: a phone call pauses and then resumes the recording
    Given I am recording a conversation with the phone microphone
    When a phone call interrupts the audio session
    Then the audio already captured is kept
    And when the call ends, recording resumes automatically into the same conversation

  Scenario: audio captured before an interruption is never lost
    Given I am recording with the phone microphone
    And thirty seconds of audio has been captured
    When the recording is interrupted and the app is closed before it resumes
    Then the thirty seconds is still saved when I reopen the app

  Scenario: a route change does not kill the recording
    Given I am recording with the phone microphone
    When the audio route changes
    Then recording continues without losing the conversation
