Feature: Recordings come over without being asked

  A person puts their phone in a pocket and walks away. The recordings they made should come over
  on their own — that is the whole point of the recorder. But this is the one place the app acts
  with nobody watching, so every reason to refuse wins over the one reason to go: a drain that
  waits costs a delay, and a drain that should not have run opens somebody's recorder over a radio
  they did not ask to use.

  Scenario: A paired recorder with recordings waiting drains on its own
    Given a recorder this phone has been set up with, holding two recordings
    Then a drain starts on its own

  Scenario: A recorder this phone has never been set up with is left alone
    Given a recorder this phone has never been set up with
    Then no drain starts
    And the reason is that the recorder is not set up here

  Scenario: Stopping everything means everything
    Given a recorder this phone has been set up with, holding two recordings
    And the owner stopped everything
    Then no drain starts
    And the reason is that the owner stopped everything

  Scenario: Another phone talking to the recorder is refused, not raced
    Given a recorder this phone has been set up with, holding two recordings
    And the recorder is already talking to another phone
    Then no drain starts
    And the reason is that another phone has it

  Scenario: A phone saving power is left to save power
    Given a recorder this phone has been set up with, holding two recordings
    And the phone is in low power mode
    Then no drain starts
    And the reason is low power mode

  Scenario: A list of what is waiting that cannot be read stops the drain
    Given a recorder this phone has been set up with, whose waiting list is corrupt
    Then no drain starts
    And the reason names the unreadable list

  Scenario: Nothing waiting is not a failure
    Given a recorder this phone has been set up with, holding nothing
    Then no drain starts
    And the reason is simply that nothing is waiting

  Scenario: A recording that came over on its own is not queued for deletion
    Given two recordings that came over without anybody asking
    Then none of them is offered up to be cleared from the recorder
