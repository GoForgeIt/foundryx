Feature: Setting up the on-device brain never becomes an endless spinner

  The first time the phone needs to transcribe on its own, it fetches a speech model —
  about 150 MB, the only bytes that ever come IN. That download can legitimately take a
  long time on a slow link, and a long wait is fine. What is not fine is a wait that has
  quietly stopped: a stalled fetch used to leave "Setting up your private on-device
  brain…" on screen forever, with no error, no retry, and no way to tell "still
  downloading" from "permanently wedged". So the app watches whether the download is
  actually ADVANCING, tells the truth the moment it stops, and offers a retry that works
  without relaunching the app.

  Scenario: a download that stops making progress fails honestly instead of spinning forever
    Given the on-device brain needs to fetch its speech model
    When the download stops making progress
    Then I am told the setup failed and how far it got
    And I am offered a way to try again
    And I am no longer told it is setting up

  Scenario: a slow download that is still making progress is left alone
    Given the on-device brain needs to fetch its speech model
    When the download keeps making progress slowly for far longer than the stall limit
    Then the on-device brain finishes setting up
    And I am not shown a failure

  Scenario: trying again after a failure works without relaunching the app
    Given the on-device brain failed to fetch its speech model
    When I choose to try again and the connection is back
    Then the on-device brain finishes setting up
    And I am no longer offered a way to try again

  Scenario: a model that is already present is unaffected
    Given the on-device brain model is already on the phone and healthy
    When the app prepares the on-device brain
    Then the on-device brain finishes setting up
    And I am not shown a failure
    And I see no setup banner at all
