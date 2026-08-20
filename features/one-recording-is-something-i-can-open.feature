Feature: A recording on a recorder is something I can open, inspect and choose

  Nick's recorder is holding nineteen recordings. The page that lists them draws a row per
  recording, and the only interactive thing a row has ever carried is "Remove it from the
  recorder" — which appears only when Solleva can prove it already holds a copy somewhere else.
  Nothing has ever been brought off that recorder, so that proof does not exist for a single one
  of the nineteen. Not one row on the page has one thing a finger can do.

  The same gap has a second half. "Bring over" asks for whatever the comparator elects — the
  smallest file this phone does not already hold — and that is the only thing anybody can ask
  for. A person looking at the recording they made this morning has no way to say "that one".

  Both are the same missing thing: there is nowhere in this app that is ABOUT one recording on a
  recorder. These scenarios are that place. A row is something you press, it opens a page that
  states what is actually known about that recording — its three places with their ages, its
  size, its date, the recorder's own name for it — and it offers the actions that recording
  really admits, and says why about the ones it does not.

  Nick's ruling is untouched and is the reason the second action is gated at all: a recording
  comes off a recorder only after Solleva has proved it holds a copy elsewhere. The page reads
  that proof through the same predicate the row read it through, so the two cannot come to
  different answers about one recording.

  Scenario: Every row in the list of recordings is something a person can press
    Given the list of recordings as the recorder page draws it
    Then the row itself is the control, not something buried inside it
    And pressing it opens the page about that one recording
    And there is a row to press, and a page for it to open

  Scenario: The page about one recording states what is known about that recording
    Given a recording the recorder listed an hour ago, which Solleva has not brought over
    Then the page about it names all three places, each with its own age
    And it states the size and the date the recorder itself reported
    And it names the recording the way the recorder names it
    And it never states where the recording is twice
    And it never states one fact twice, one band apart

  Scenario: A recording Solleva cannot prove it holds elsewhere is still offered removal
    Given a recording the recorder listed an hour ago, which Solleva has not brought over
    Then the page about it offers to take it off the recorder
    And it says what that would cost, instead of showing nothing
    And a recording Solleva has proved it holds elsewhere IS offered that action
    And over every way one recording can be placed, the page and the shelf row agree

  Scenario: The owner can ask for that one recording rather than the one Solleva picked
    Given a recorder holding three recordings and none of them yet in Solleva
    Then the page about every one of them offers to bring that one over
    And the one Solleva would have chosen on its own is only one of the three
    And asking for a recording the shelf cannot answer for is refused rather than guessed

  Scenario: A recording already here, or too big to carry, says so instead of offering a tap
    Given a recording this phone is already holding
    Then the page about it does not offer to bring it over, and says Solleva already has it
    And a recording bigger than Solleva can carry says that instead of offering the tap
    And the ceiling it is measured against is the one the transfer itself refuses on

  Scenario: What a removal would cost is named from where the recording is, not from the tier
    Given a recording the recorder listed an hour ago, which Solleva has not brought over
    Then the page says nothing else holds it, whichever brain is on
    And a Vault is suggested there, and the removal is still offered
    And a recording this phone is holding is told it would leave one copy, on this phone
    And every one of them reaches the page it is about

  Scenario: The page about one recording is held to the same words as the page it opens from
    Given every body the recorder page is written in
    Then every one of them takes at least one sentence from the kit
    And the page about one recording is one of the bodies that is read
