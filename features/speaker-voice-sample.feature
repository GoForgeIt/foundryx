Feature: Hear a speaker's voice while naming them

  Naming a speaker requires knowing WHO they are — and the only ground truth is their
  voice. Tapping a line in the transcript opens the tag sheet with "Hear this voice": it
  plays a short clip of THAT line — the exact piece of the conversation the user was
  looking at — fetched as a small windowed slice, never the whole recording. (Earlier it
  always played the speaker's globally-longest utterance somewhere else in the
  conversation, so it "didn't play the selected piece" — b232.) When the sheet is opened
  WITHOUT a specific line (the "review speakers" jump), it falls back to a representative
  sample: that speaker's longest, most recognizable utterance. A speaker whose segments
  carry no timestamps simply doesn't offer playback (never a broken button).

  Scenario: hearing the exact line you tapped
    Given a recorded conversation with diarized speakers
    When I tap the line "short bit from speaker two" to tag its speaker
    And I tap "Hear this voice"
    Then the sample plays that exact line's audio
    And the sample covers only that speaker's own speaking time
    And the sample is not that speaker's longest utterance

  Scenario: reviewing a speaker without tapping a line plays a representative sample
    Given a recorded conversation with diarized speakers
    When I review "Speaker 2" without tapping a specific line
    And I tap "Hear this voice"
    Then the sample played is "Speaker 2"'s longest utterance

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
