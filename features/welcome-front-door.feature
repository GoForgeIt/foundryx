Feature: The welcome is the front door — the old connection page never gates

  Track 20260715T1502 (re-cut 2026-07-17, Nick 2026-07-16): the old connection
  intro page must not appear as a gate on any path. The welcome surface fronts
  the app; live connection status to the computer (door/hub) shows on the
  welcome while it gates, and inside the app afterwards — never as a blocking
  interstitial.

  Scenario: an established user meets the welcome, not the old connection page, while connecting
    Given I am signed in and have used the app before
    And my computer is still being reached
    When I launch the app
    Then the welcome page fronts the app
    And it shows that it is connecting to my computer
    And the old connection page is not shown

  Scenario: the connection status on the welcome settles from connecting to connected
    Given I am signed in and have used the app before
    And the welcome is fronting the app while my computer is being reached
    When the connection to my computer is established
    Then the welcome shows I am connected with my account

  Scenario: entering the app from the welcome never repeats the welcome
    Given I am signed in and have used the app before
    And the welcome is fronting the app
    When I choose to go into the app
    Then I am in the app
    And the welcome does not appear again after entry

  Scenario: skipping the welcome persists and later launches go straight in
    Given I am signed in and have used the app before
    And the welcome is fronting the app
    When I choose to skip the welcome from now on
    And I launch the app again
    Then I go straight into the app with no welcome and no connection page
    And the connection to my computer still shows inside the app

  Scenario: signing out from inside the app returns to the sign-in welcome
    Given I am signed in and have used the app before
    And the welcome is fronting the app
    When I choose to go into the app
    And I sign out from settings
    Then the welcome page fronts the app with the sign-in choices again
    And the old connection page is not shown

  Scenario: a signed-out user gets the sign-in choices on the welcome
    Given a fresh install that has never signed in
    When I launch the app
    Then the welcome page fronts the app with the sign-in choices
    And the old connection page is not shown

  # Regression (build 288): after "skip the welcome" (letStraightIn), signing out
  # left a DEAD gate — the front door returned .none, so neither the provider
  # buttons nor a working action showed and there was no way back in. Sign-in is
  # required FIRST, before letStraightIn is honored (mirrors the RootGate fix).
  Scenario: signing out returns to the sign-in choices even after skipping the welcome
    Given I am signed in and have used the app before
    When I choose to skip the welcome from now on
    And I sign out from settings
    Then the welcome page fronts the app with the sign-in choices again

  Scenario: a fresh install continues into onboarding without seeing the welcome twice
    Given a fresh install that has never signed in
    And the sign-in welcome is fronting the app
    When I sign in and go into the app
    Then onboarding continues without repeating the welcome
