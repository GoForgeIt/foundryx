Feature: Hear a speaker's voice while naming them

  Naming a speaker requires knowing WHO they are — and the only ground truth is their
  voice. The speaker tag sheet offers "Hear this voice": it plays a short sample of
  THAT speaker's own audio (their longest utterance in this conversation), fetched as
  a small clip — never the whole recording — so the user can listen, recognize the
  person, and type their name in one motion. A speaker whose segments carry no
  timestamps simply doesn't offer playback (never a broken button).

  Scenario: hearing a speaker's voice sample from the tag sheet
    Given a recorded conversation with diarized speakers
    And speaker "Speaker 2" has timestamped utterances
    When I open the tag sheet for "Speaker 2"
    And I tap "Hear this voice"
    Then a short audio sample of "Speaker 2" plays
    And the sample covers only that speaker's own speaking time

  Scenario: the sample picks the speaker's longest utterance
    Given a recorded conversation where "Speaker 1" spoke three times
    When I tap "Hear this voice" for "Speaker 1"
    Then the sample played is "Speaker 1"'s longest utterance

  Scenario: playback stops when the tag sheet closes
    Given a voice sample for "Speaker 2" is playing
    When I close the tag sheet
    Then audio playback stops

  Scenario: a speaker without timestamps offers no playback
    Given a recorded conversation where "Speaker 3" has no utterance timestamps
    When I open the tag sheet for "Speaker 3"
    Then there is no "Hear this voice" control

  Scenario: the recording's audio is no longer available
    Given a recorded conversation whose audio has been pruned from the desktop
    When I tap "Hear this voice" for a speaker
    Then I see that the voice sample is unavailable
    And the tag sheet remains usable for naming

  Scenario: naming flows directly after listening
    Given I just heard "Speaker 2"'s voice sample
    When I enter "Sarah" as the speaker name and save
    Then the conversation shows "Sarah" where "Speaker 2" appeared
