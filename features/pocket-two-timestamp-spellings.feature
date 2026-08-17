Feature: A recorder that spells its times two ways is still read correctly

  One recorder names its recordings two different ways. Nine of the nineteen on the owner's own
  device are spelled one way and the rest the other, and nothing about that is visible to the
  person holding it — it is the same recorder, the same day, the same recording.

  So neither spelling may be treated as the real one. A recording named the second way must show
  the time it was made, sort into its true place among the others, and be filed on the day it was
  recorded rather than the day somebody happened to collect it.

  And where a time genuinely cannot be read, nothing is invented. A recording filed under today,
  silently, because its time was unreadable is worse than one that says its time is unknown.

  Scenario: A recording named the other way still shows the time it was made
    Given a recorder holding one recording named each of the two ways it names them
    Then both recordings show the time of day they were made
    And neither of them shows the recorder's raw name for the file instead of a time

  Scenario: Recordings made minutes apart are listed in the order they were made
    Given a recorder holding recordings made minutes apart on one day, named both ways
    When Solleva puts them in the order it shows them
    Then they are listed newest first by when they were actually made
    And the way each one happens to be named does not change where it sits

  Scenario: A recording is filed on the day it was made, not the day it was collected
    Given a recording made on an earlier day and named the other way
    When I bring it over
    Then the conversation is dated the day it was made
    And it is not dated the day I collected it

  Scenario: A time this build cannot read is never quietly replaced with today
    Given a recording whose time is spelled in a way this build has never seen
    When I bring it over
    Then Solleva says the recording's own time is not known
    And the recording is still brought over
