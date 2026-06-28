Feature: A live, on-device transcript preview while recording
  As someone whose Omi conversations are captured,
  I want to see the words appear as I speak, transcribed on my own phone,
  so I get instant feedback long before the authoritative transcript arrives.

  The live preview is a FAST / PROVISIONAL layer: it runs on-device (Apple
  SpeechAnalyzer on iOS 26+, falling back to on-device SFSpeechRecognizer), it is
  strictly additive to the durable capture pipeline, and it never replaces the
  authoritative Kiln transcript — it is ephemeral display only. On devices that
  don't support it, capture behaves exactly as before with no preview.

  Scenario: words appear as a faded live stream while a conversation is recording
    Given an ambient capture is recording a conversation
    And on-device live transcription is available
    When the recognizer reports tentative words as I speak
    Then I see those words appear as a faded live preview under the capture meter

  Scenario: tentative words are corrected when the recognizer finalizes them
    Given an ambient capture is recording a conversation
    And on-device live transcription is available
    When a tentative word is later finalized into a corrected form
    Then the live preview updates the word to its corrected, finalized form

  Scenario: the most-recent word is faded until it locks in
    Given an ambient capture is recording a conversation
    And on-device live transcription is available
    When the recognizer reports tentative trailing words as I speak
    Then the newest word is shown faintest and the words just before it ramp up to full
    And each word snaps to full opacity the moment the recognizer finalizes it

  Scenario: the live preview is provisional and never replaces the Kiln transcript
    Given a conversation showed a live on-device preview while recording
    When the conversation ends and Kiln returns its authoritative transcript
    Then the authoritative transcript is what is stored and shown afterward
    And the live preview is cleared when the conversation closes

  Scenario: live transcription is unavailable on an unsupported device
    Given a device that does not support on-device live transcription
    When an ambient capture records a conversation
    Then no live preview is shown and capture proceeds unchanged
