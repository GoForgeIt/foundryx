Feature: Resume recording into an existing conversation

  Scenario: Resume an existing conversation from its detail view
    Given I have a saved conversation with local audio
    When I resume recording from that conversation
    And new audio is captured
    Then the same conversation is active
    And the new audio is appended after the existing audio
    And no duplicate conversation is created

  Scenario: Ending a resumed conversation starts the next capture fresh
    Given I have resumed a saved conversation with local audio
    When I start a new conversation
    Then the resumed conversation is finalized again
    And the next active conversation is fresh

  Scenario: A pruned conversation cannot be resumed
    Given I have a saved conversation whose local audio was pruned
    Then I cannot resume recording from that conversation

  Scenario: Resume respects the active source policy
    Given I am already recording a conversation
    And I have another saved conversation with local audio
    When I try to resume recording from the saved conversation
    Then the current recording remains active
    And the saved conversation is not reopened
