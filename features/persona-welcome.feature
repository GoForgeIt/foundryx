Feature: The welcome adapts to who is arriving

  The first screen speaks to the person in front of it: an independent expert, a
  person organizing their life, or a firm. One flow skeleton; only the words and
  the artwork route. The choice is quiet ("What brings you here?"), sits above
  the artwork, defaults to the individual voice, persists, and can be changed
  later in Settings. Sign-in stays first (locked decision #5); the welcome shows
  once after the first sign-in — including for established installs after an
  update — and "Set up later" dismisses it forever. It stays reachable from
  Settings ("Welcome & who it's for").

  Scenario: the welcome speaks the individual voice by default
    Given I have just signed in for the first time
    When the welcome shows
    Then the headline reads "It adapts to you."
    And the privacy line says my memory stays on my devices

  Scenario: choosing the firm voice re-renders the welcome in place
    Given the welcome is showing
    When I choose "For my firm"
    Then the headline reads "One standard, inside your perimeter."
    And I am still on the welcome step

  Scenario: choosing the expert voice re-renders the welcome in place
    Given the welcome is showing
    When I choose "For my work"
    Then the headline reads "Take the work back."

  Scenario: every persona shows the one canonical privacy line
    Given the persona copy table
    Then every persona's privacy line reads exactly "Your memory stays on your devices, under your keys."

  Scenario: the welcome offers Continue and Set up later with the switch above the art
    Given the welcome is showing
    Then the primary action reads "Continue"
    And the quiet action reads "Set up later"
    And the "What brings you here?" switch sits above the artwork

  Scenario: the welcome shows once after sign-in
    Given I have just signed in
    And I have not seen the persona welcome
    When the app decides what to show
    Then the persona welcome is presented before the tabs

  Scenario: an established install still sees the welcome once after an update
    Given I have recordings from before the welcome existed
    And migration marked my onboarding complete
    When the app decides what to show
    Then the voice and consent onboarding is not re-presented
    But the persona welcome is presented once

  Scenario: Set up later dismisses the welcome forever
    Given the welcome is showing
    When I choose "Set up later"
    Then the welcome is marked seen
    And it is not presented again on the next launch

  Scenario: my choice persists across launches
    Given I chose "For my work" on the welcome
    When I relaunch the app
    Then the persona is expert

  Scenario: the individual voice never says apprentice
    Given the persona copy table
    Then the individual welcome copy does not contain "apprentice"

  Scenario: I can change who it speaks to from Settings
    Given I completed onboarding as an individual
    When I change the persona to firm in Settings
    Then the persona is firm

  Scenario: the welcome stays reachable from Settings
    Given I dismissed the welcome with "Set up later"
    When I open Settings
    Then a "Welcome & who it's for" row reopens the persona welcome
