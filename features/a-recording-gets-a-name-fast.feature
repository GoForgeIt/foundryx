Feature: a recording gets a name fast, and the name it gets is honest about where it came from

  Nick, in his words: "it would be great for as soon as any one comes in for it to
  generate a title for it based on the first 30s or 60s or so until the full summary
  and recording processing is done".

  So the moment ANY transcript exists, the recording is named from its opening
  window — and that name is marked as early, because it was read from the opening
  and not from the whole thing. When the real name arrives it replaces the early one
  ONCE, and never goes back.

  THE WINDOW IS ONLY A TIME WINDOW WHEN THERE ARE TIMES. A diarized reply carries
  per-segment milliseconds and a paragraph reply carries seconds, so "the first 45
  seconds" is a measurement. A flat transcript carries no clock at all, so calling
  its opening "the first 60 seconds" would be a figure with nothing behind it — it
  is named from its opening WORDS and says so.

  Scenario: a transcript with timings is named from its opening seconds
    Given a diarized transcript whose first 60 seconds are about the roof quote
    When the recording is named early
    Then it has an early name
    And the early name is marked as early
    And the note says how many seconds it read

  Scenario: a short recording never claims to have read more than it has
    Given a diarized transcript that is only 12 seconds long
    When the recording is named early
    Then the note says how many seconds it read
    And the note does not claim 60 seconds

  Scenario: a transcript with no timings is named from its opening words
    Given a flat transcript with no timings at all
    When the recording is named early
    Then it has an early name
    And the note says it read the opening words
    And the note claims no seconds

  Scenario: a transcript too short to name anything offers no name
    Given a transcript of three words
    When the recording is named early
    Then it has no early name

  Scenario: the settled name replaces the early one
    Given a row showing an early name
    When the settled name arrives
    Then the row shows the settled name
    And the row no longer marks the name as early

  Scenario: the row never falls back to the early name once settled
    Given a row showing the settled name
    When a later reading carries no settled name
    Then the row still shows the settled name

  Scenario: an early name never overwrites a settled one
    Given a row showing the settled name
    When a different early name is offered
    Then the row still shows the settled name

  Scenario: a row with nothing to show yet shows no invented name
    Given a row that has been offered neither name
    Then the row shows no name
    And the row does not mark a name as early
