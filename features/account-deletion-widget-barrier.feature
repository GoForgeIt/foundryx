Feature: Deleting one account cannot be trapped by another account's widget

  Scenario: Another account's widget does not block deletion
    Given the widget belongs to another live account
    When I delete my account
    Then my deletion completes
    And the other account's widget payload remains readable

  Scenario: A stale widget owner cannot hide my deleted account's payload
    Given the widget owner tag names another account but the payload belongs to my account
    When I delete my account
    Then my deletion completes
    And no widget payload belonging to my deleted account is readable

  Scenario: An unprovable widget withdrawal fails closed without trapping the app
    Given the widget store cannot prove a durable withdrawal
    When I delete my account
    Then deletion remains incomplete
    And I can continue from the front door with a recovery action
