Feature: Copy a whole transcript

  A user can copy an entire conversation transcript to the clipboard in one tap,
  so they can paste it into notes, a message, or a doc. When speakers are known,
  the copied text is labelled by speaker turn; otherwise it's the flat transcript.

  Scenario: copy a flat transcript
    Given a conversation whose transcript has no speaker labels
    When I copy the transcript
    Then the clipboard holds the full transcript text

  Scenario: copy a speaker-labelled transcript
    Given a conversation with two identified speakers
    When I copy the transcript
    Then the clipboard holds each speaker turn labelled by speaker
    And the turns are in spoken order

  Scenario: the copy action is only offered when there is a transcript
    Given a conversation whose transcript has not loaded yet
    When I open the conversation
    Then I am not offered a copy action
