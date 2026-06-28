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

  # --- all-time metadata + 14-day transcript cache + load-on-demand ---

  Scenario: Every conversation shows a name and description in the list
    Given conversations from all time, including ones whose transcript text is no longer cached
    When I view the conversation list
    Then each conversation shows its name and description from the durable card metadata
    And the conversation stays browsable even after its transcript and audio were pruned

  Scenario: A recent conversation's transcript is cached on sight
    Given a conversation recorded within the last 14 days that has been transcribed
    When its card appears in the list
    Then the phone fetches and caches its transcript locally
    And opening it later shows the transcript instantly, even offline

  Scenario: An older conversation loads its transcript on demand
    Given a conversation older than 14 days whose transcript text is not cached
    When I open it
    Then the transcript is not auto-fetched and I see a Load transcript affordance
    When I tap Load transcript or pull to refresh
    Then the phone fetches the transcript from the door and shows it
