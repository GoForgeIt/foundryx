Feature: The ambient step tells me the truth about the sample nudge

  The ambient step offers to let my phone privately notice moments while I speak. When I
  tap "Turn it on" it promises me a sample notification — "We just sent a sample nudge so
  the first real one is never a surprise" — so the first real one is familiar.

  It was not sending one. The sample fired through a function that began by looking up my
  account, and during onboarding I do not have one yet, so it returned without posting
  anything and the screen announced the send anyway. Nothing had even asked me for
  notification permission at that point, so iOS would have dropped the nudge in any case.

  Either the nudge goes out, or the step says it could not. It never says both.

  Scenario: the nudge really went out
    Given I have just turned ambient intelligence on during onboarding
    When the phone accepts the sample nudge
    Then the step tells me a sample nudge was sent
    And the step points me at my lock screen

  Scenario: I refuse the notification permission
    Given I have just turned ambient intelligence on during onboarding
    When I refuse permission to send me notifications
    Then the step does not claim a sample nudge was sent
    And the step tells me how to turn notifications on
    And ambient intelligence is still on

  Scenario: the nudge could not be scheduled
    Given I have just turned ambient intelligence on during onboarding
    When the sample nudge cannot be scheduled
    Then the step does not claim a sample nudge was sent
    And ambient intelligence is still on

  Scenario: nothing is claimed before the phone has answered
    Given I have just turned ambient intelligence on during onboarding
    Then the step does not claim a sample nudge was sent

  Scenario: no outcome but a real send may claim a send
    Given I have just turned ambient intelligence on during onboarding
    Then only a scheduled nudge claims a nudge was sent
    And no wording in the app claims a nudge the app cannot have verified

  Scenario: the step asks for notification permission where it makes the promise
    Given I have just turned ambient intelligence on during onboarding
    Then the sample nudge asks me for notification permission
    And the sample nudge can be shown while the app is open

  Scenario: the notes-destination buttons share one alignment
    Given the screen that asks where my notes live is showing
    Then the choice buttons are aligned the same way as the screen
    And the choice buttons span the column rather than a box of their own
