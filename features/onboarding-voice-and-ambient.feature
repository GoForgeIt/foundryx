Feature: First-run onboarding teaches the owner's voice and offers ambient intelligence

  After the first sign-in, a short onboarding flow runs ONCE: it invites the user to
  teach FoundryX their voice (a ~20-second read-aloud that becomes the OWNER voice —
  the proof that later lets only the owner command their agent) and to opt into
  ambient intelligence (default OFF — declining leaves capture exactly as it is
  today). Every step is skippable; skipping never blocks the app, and both steps
  remain reachable later from Settings. The flow never runs again once completed
  or dismissed.

  Scenario: onboarding appears once after first sign-in
    Given I have just signed in for the first time
    Then the onboarding flow is presented
    When I complete or dismiss it
    And I relaunch the app
    Then the onboarding flow is not presented again

  Scenario: teaching my voice records an owner sample
    Given the onboarding voice step is showing
    When I read the passage aloud until the recording completes
    Then an owner voice sample is stored on the phone
    And the voice step shows it was captured

  Scenario: the voice sample must be long enough to be usable
    Given the onboarding voice step is showing
    When I stop reading after a moment
    Then no owner voice sample is stored
    And I can try again or skip

  Scenario: skipping the voice step stores nothing
    Given the onboarding voice step is showing
    When I skip it
    Then no owner voice sample is stored
    And the flow moves on

  Scenario: ambient intelligence is offered as an explicit opt-in
    Given the onboarding ambient step is showing
    Then ambient intelligence is off
    When I choose to enable it
    Then ambient intelligence is enabled

  Scenario: declining ambient leaves everything off
    Given the onboarding ambient step is showing
    When I continue without enabling it
    Then ambient intelligence remains off

  Scenario: an already-onboarded user is never re-prompted
    Given I completed onboarding on a previous version
    When the app launches
    Then the onboarding flow is not presented
