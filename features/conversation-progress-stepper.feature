Feature: See where a conversation is in processing

  While a conversation is still being processed, the detail view shows a stepper —
  Recorded → Saved → Transcribing → Ready — with the current step highlighted, so
  the user sees WHERE it is and that it's moving, instead of a bare spinner. Once the
  transcript is ready it's shown directly and the stepper steps aside.

  Scenario: a transcribing conversation shows its position
    Given a conversation whose transcript is still being produced
    When I open it
    Then I see the steps Recorded and Saved marked complete
    And I see the Transcribing step marked as in progress
    And I see the Ready step still ahead

  Scenario: a ready conversation shows the transcript, not the stepper
    Given a conversation whose transcript is ready
    When I open it
    Then I see the transcript
    And I do not see the progress stepper

  Scenario: a failed conversation shows the failure at the transcribing step
    Given a conversation that failed to transcribe
    When I open it
    Then the Transcribing step is marked failed
