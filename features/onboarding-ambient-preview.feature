Feature: I can see what ambient intelligence looks like before I say yes

  The ambient step asks me to let my phone privately notice moments in what I say and
  offer to help. Today it asks in words alone, on a mostly empty screen, and only shows
  me a real example AFTER I have already accepted. That is backwards: the sample nudge
  is the first concrete thing, and it arrives once consent is already given. Instead the
  empty space carries worked examples of the cards ambient intelligence would create,
  rendered the same way they appear on a voice note — so I am agreeing to something I
  have already seen.

  Scenario: examples are shown before I decide
    Given the onboarding ambient step is showing
    Then I see example ambient intelligence cards
    And ambient intelligence is still off

  Scenario: the examples show the moments it notices
    Given the onboarding ambient step is showing
    Then each example shows the moment that triggered it
    And each example shows what my agent would offer to do

  Scenario: the examples are clearly examples
    Given the onboarding ambient step is showing
    Then the examples are labelled as examples
    And no example is stored as one of my real cards

  Scenario: accepting still sends the sample nudge
    Given the onboarding ambient step is showing
    When I choose to enable it
    Then ambient intelligence is enabled
    And a sample notification is sent so the first real one is familiar

  Scenario: declining after seeing the examples leaves everything off
    Given the onboarding ambient step is showing
    When I continue without enabling it
    Then ambient intelligence remains off
    And no example is stored as one of my real cards
