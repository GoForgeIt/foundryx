Feature: The phone is honest about tentative speaker matches
  As someone reading a diarized conversation,
  I want a guessed speaker name shown only when the match is strong,
  and I never want a raw similarity dressed up as a confidence percentage,
  so I trust the names I see and make good tagging decisions.

  Scenario: A weakly-matched voice is shown as an unnamed speaker
    Given a conversation whose voice is only weakly matched to a known person
    When I look at that speaker in the transcript
    Then the speaker reads as an unnamed numbered speaker
    And the guessed name is not shown anywhere in the transcript

  Scenario: A strong suggestion never shows a percentage
    Given a conversation whose voice is strongly matched to a known person
    When I look at that speaker in the transcript
    Then the speaker reads with the person's name
    And the match is flagged as a suggestion
    And no rendered text shows a percentage
