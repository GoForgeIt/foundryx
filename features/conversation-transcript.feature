Feature: See a conversation's transcript on the phone (Phase B)
  As someone whose Omi conversations are captured and transcribed,
  I want to tap a saved conversation and read its transcript,
  so the capture pipeline produces something I can actually see.

  Scenario: A transcribed conversation shows its transcript
    Given a capture that has been transcribed by Lore
    When I tap the conversation in the capture timeline
    Then I should see the conversation's transcript text
    And I should see its time range

  Scenario: A conversation still being processed shows a friendly state
    Given a capture that has reached the desktop but is not yet transcribed
    When I tap the conversation in the capture timeline
    Then I should see "Transcript still processing"
    And I should not see an error
