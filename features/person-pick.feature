Feature: Choosing an existing person when tagging a speaker
  As someone tagging who spoke in a conversation,
  I want to pick a person I have named before instead of typing a new name,
  so I bind the right existing person and never create a duplicate by mistyping.

  Scenario: The tag sheet offers the people I already know
    Given people I have named before
    When I open the tag sheet for an unnamed speaker
    Then I can choose from the existing people

  Scenario: Typing narrows to the person I mean
    Given people I have named before
    When I type "nic" to find a person
    Then the existing person "Nick Rinard" is offered

  Scenario: A likely match is surfaced but nothing is chosen for me
    Given people I have named before
    And the speaker is tentatively matched to "Nick"
    When I open the tag sheet for that speaker
    Then "Nick Rinard" is surfaced as the likely person
    And no person is selected until I choose one

  Scenario: Creating a new person is offered only when nobody matches
    Given people I have named before
    When I type "Zoe Vega" to find a person
    Then creating a new person is offered
    When I type "Nicholas" to find a person
    Then creating a new person is not offered

  Scenario: Picking an existing person binds that person, not a duplicate
    Given people I have named before
    When I pick the existing person "Nick Rinard"
    Then the saved change binds that person's existing identity
    And the saved change carries no stale speaker guess

  Scenario: An offline pick keeps its binding to sync later
    Given people I have named before
    And my computer cannot be reached
    When I pick the existing person "Nick Rinard"
    Then the pick is saved on my phone with the person's identity
    And the binding is still there after the app relaunches
