Feature: The ambient step says what the phone did

  The ambient step promises me a notification. Whether one went out is a fact about my
  phone, so the only honest way to hold this is to give the app a phone and ask it what it
  was told to do.

  This is that feature. It runs inside the shipping app, against the shipping notifier, with
  a scripted notification centre standing in for iOS — so a scenario here counts what the app
  actually asked for and actually handed over. The guards it replaces read the notifier's own
  source text, and three one-line mutations to that source shipped 1536/1536 green: putting
  the account guard back so the sample was swallowed in silence, changing the denial arm so a
  user who tapped "Don't Allow" was told to check their lock screen, and inserting a silent
  return into the delivery path.

  Scenario: my phone accepts the sample and the step says so
    Given a phone that has not been asked about notifications
    And there is no account yet, because this is onboarding
    When I turn ambient intelligence on
    Then my phone was asked for notification permission exactly once
    And exactly one notification was handed to my phone
    And the step tells me a sample nudge was sent

  Scenario: I refuse the notification permission
    Given a phone that will refuse notification permission
    And there is no account yet, because this is onboarding
    When I turn ambient intelligence on
    Then my phone was asked for notification permission exactly once
    And nothing was handed to my phone
    And the step does not claim a sample nudge was sent
    And the step tells me how to turn notifications on
    And ambient intelligence is still on

  Scenario: my phone already says no
    Given a phone that has already refused notifications
    And there is no account yet, because this is onboarding
    When I turn ambient intelligence on
    Then my phone was not asked for notification permission again
    And nothing was handed to my phone
    And the step does not claim a sample nudge was sent

  Scenario: my phone rejects the notification itself
    Given a phone that allows notifications but rejects the request
    And there is no account yet, because this is onboarding
    When I turn ambient intelligence on
    Then exactly one notification was handed to my phone
    And the step does not claim a sample nudge was sent
    And ambient intelligence is still on

  Scenario: my phone never answers
    Given a phone that never answers
    And there is no account yet, because this is onboarding
    When I turn ambient intelligence on and wait for the step to give up
    Then the step does not claim a sample nudge was sent
    And the step is no longer telling me it is checking

  Scenario: my phone cannot even name my account, and the sample still goes out
    Given a phone that has not been asked about notifications
    And my phone cannot resolve an account scope at all
    When I turn ambient intelligence on
    Then my phone was asked for notification permission exactly once
    And exactly one notification was handed to my phone
    And the step tells me a sample nudge was sent

  Scenario: launching the app asks me for nothing
    Given a phone that has not been asked about notifications
    When the app sets up its notifications the way launch does
    Then my phone was not asked for notification permission at all
    And nothing was handed to my phone
    And the banner can be shown while the app is open
