Feature: Solleva never deletes anything you did not ask it to

  A recorder holds the only copy of a recording until somebody brings it over. So the promise
  that mattered was never "Solleva has no way to delete" — it was "nothing leaves the recorder
  unless we can prove we already hold it somewhere else."

  The promise Solleva used to print was the first one, and it was a description of a missing
  feature rather than a policy. It was also about to become untrue: the recorder's delete is a
  single-letter command that has been decoded and is public, so a gate asserting no such command
  exists would have locked out a form we already hold, and would have gone green on an empty
  codebase besides.

  These scenarios hold the promise a person can actually rely on. Every command Solleva composes
  for a recorder is counted, and a deletion nobody chose is refused before it reaches the radio.
  The population is asserted to be non-empty first, because "none of them was a delete" is
  satisfied by a recorder nobody ever spoke to.

  Nothing here composes a deletion. The consent a deletion would need exists, and it cannot be
  made by accident; the recording it names is out of scope until a person can choose one.

  Scenario: Nothing Solleva does on its own deletes anything from a recorder
    Given a recorder holding three recordings and none of them yet in Solleva
    When Solleva brings one over, retries a failed one, runs its retention sweep, and sends what it is holding
    Then Solleva composed commands to that recorder
    And not one of them was a delete

  Scenario: A recording is never removed from a recorder because something decided it for me
    Given a recorder holding three recordings and none of them yet in Solleva
    When something inside Solleva asks that recorder to forget a recording nobody chose
    Then the recorder is never asked
    And Solleva records that it refused, and that the reason was that nobody chose it

  Scenario: Asking a recorder to forget a recording cannot happen by accident
    Given the way a person's choice to remove a recording is carried
    Then there is exactly one way to make that choice, and it names the one recording
    And nothing can make that choice without going through it

  Scenario: A recording Solleva cannot prove it holds elsewhere cannot be chosen for removal
    Given a recording that is on the recorder and nowhere else Solleva can prove
    Then a person's choice to remove it cannot even be recorded
    And the same is true when Solleva has simply never checked
    And a recording Solleva can prove it holds elsewhere CAN be chosen, so the bar is not just always-no

  Scenario: Turning on automatic clearing is a second path, and it meets the same bar
    Given a recording that is on the recorder and nowhere else Solleva can prove
    Then arming a recorder to clear itself cannot record a choice about that recording either
    And a recording Solleva holds elsewhere can be cleared by an armed recorder
    And Solleva can tell the two paths apart afterwards

  Scenario: A recorder listing what it holds is never read as a recording being deleted
    Given the answers a recorder gives while it is listing what it holds
    Then not one of them reads as a recording having been removed
    And the answer to a real removal still reads as one, so the reading is not blind

  Scenario: The promise a person reads is the promise Solleva keeps
    Given the recorder panel a person reads before bringing anything over
    Then it promises never to delete anything they did not ask it to
    And it no longer claims Solleva cannot delete at all
    And nothing Solleva does on its own is counted as something a person asked for
