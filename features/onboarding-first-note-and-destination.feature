Feature: Onboarding ends with a note I made, an answer about it, and an honest ceiling

  Onboarding used to end on a PERMISSION — the ambient opt-in — and then drop me on an
  empty library with no idea what to do next, and no mention that a Vault even exists.
  Instead the flow ends on a win, a demonstration, and a choice: I make my first voice
  note (and watch it transcribe while I speak), I ask a question about what I just said
  and get an answer from the on-device model, and only THEN am I shown what changes if
  my notes live somewhere bigger.

  The ceiling is discovered, not advertised. Having just felt "ask about this note", the
  difference that matters is stated as one fact — asking across everything I have ever
  said — rather than a list of product names. The free tier is never described as
  lacking, and picking the Vault is how cell provisioning starts. Every step is
  skippable, and skipping lands me somewhere that tells me what to do rather than on an
  empty screen.

  Scenario: the flow does not end on the consent step
    Given I have just answered the ambient intelligence question
    Then I am invited to make my first voice note
    And onboarding is not finished yet

  Scenario: my first voice note is a real note
    Given I am on the first voice note step
    When I record a short voice note
    Then the note is saved to my library
    And my library is no longer empty

  Scenario: I see the words appear while I speak
    Given I am on the first voice note step
    When I record a short voice note
    Then I see the live transcript while I am speaking

  Scenario: the library's own recorder does not take over the flow
    Given I am on the first voice note step
    When I record a short voice note
    Then the library's full-screen recorder stays down
    And I am still in the onboarding flow

  Scenario: after making a note I get to ask it something
    Given I have made my first voice note
    Then I am invited to ask a question about what I just said
    And onboarding is not finished after the note

  Scenario: the answer comes from the note I just made
    Given I am on the ask-it step
    When I ask a question about my note
    Then I get an answer drawn from what I just said
    And the answer was produced on this phone

  Scenario: only then am I shown where my notes could live
    Given I have asked a question about my note
    Then I am shown what changes if my notes live somewhere bigger
    And I can choose this phone, my computer, or my Vault

  Scenario: the ceiling is stated as one difference, not a feature list
    Given I am shown what changes if my notes live somewhere bigger
    Then the difference offered is asking across everything I have said
    And every point compares both choices
    And staying on this phone is never described as having nothing

  Scenario: choosing my Vault starts cell provisioning
    Given I am shown what changes if my notes live somewhere bigger
    When I choose my Vault
    Then Vault setup begins

  Scenario: choosing this phone finishes onboarding
    Given I am shown what changes if my notes live somewhere bigger
    When I choose this phone
    Then onboarding is finished
    And my notes are kept on this phone

  Scenario: skipping the first note still tells me what to do next
    Given I am on the first voice note step
    When I skip it
    Then onboarding is finished
    And my library invites me to make my first voice note

  Scenario: the ending never runs twice
    Given I finished onboarding including the destination choice
    When the app launches
    Then the onboarding flow is not presented
