Feature: The welcome adapts to who is arriving

  The first screen speaks to the person in front of it: an independent expert, a
  person organizing their life, or a firm. One flow skeleton; only the words and
  the artwork route. The choice is quiet ("What brings you here?"), defaults to
  the individual voice, persists, and can be changed later in Settings. The
  voice-teach and ambient steps never fork by persona.

  Scenario: the welcome speaks the individual voice by default
    Given I have just signed in for the first time
    When the welcome shows
    Then the headline reads "It adapts to you."
    And the privacy line says my memory stays on my devices

  Scenario: choosing the firm voice re-renders the welcome in place
    Given the welcome is showing
    When I choose "For my firm"
    Then the headline reads "Your data stays under your control."
    And I am still on the welcome step

  Scenario: choosing the expert voice re-renders the welcome in place
    Given the welcome is showing
    When I choose "For my work"
    Then the headline reads "The expert work is why they hire you."

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
