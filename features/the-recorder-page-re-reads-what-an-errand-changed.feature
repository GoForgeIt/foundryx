Feature: The recorder page re-reads what an errand changed

  A check, a transfer and a removal all change what this account holds for a recorder, and each
  of them writes it to the phone's own disk. The page the errand was run from renders the value
  a NavigationLink captured, so unless something reads it back, the owner watches an errand
  finish and watches nothing change.

  The page did read it back — after a CHECK, and only after a check. The comparison that decided
  when lived in a SwiftUI body, which nothing in this repository can compile, so a one-character
  edit moving it to the wrong edge shipped green through every gate this app has. And a removal,
  whose entire purpose is to reclaim room and which re-reads how full the recorder is on the same
  session it removed from, was not one of the events that counted: the one figure a person is
  staring at while they free up space was the one figure that stayed frozen.

  These scenarios run inside the shipping application, against the shipping models, over a
  scripted radio. Nothing here asserts that a string is present in a file.

  Scenario: The numbers a finished check measured are on the page the check was run from
    Given a remembered recorder whose page has never been told anything
    When I ask that recorder what it is holding
    Then that page shows the charge and the firmware the recorder just answered
    And no fact on that page still offers to go and ask

  Scenario: Freeing up room changes the free-space figure on the page
    Given a remembered recorder holding a recording Solleva has already taken into its keeping
    When that recording is removed from the recorder
    Then that page shows more free space than it showed before the removal

  Scenario: A newer reading from the list is not overridden by an older re-read
    Given a recorder page that has re-read what a check wrote
    When the list behind that page pushes a newer reading
    Then that page shows the newer reading

  Scenario: A page that could not read this account's records does not date its numbers confidently
    Given a recorder page that has re-read what a check wrote
    When this account's record of that recorder can no longer be read
    Then that page says it could not read what this account has saved for that recorder
    And that page still shows the last numbers the recorder gave
