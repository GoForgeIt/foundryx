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

  # Nick hit this on a real device, TestFlight 774493: "delete everything" stopped
  # at "Clearing the widget didn't finish (exposureBarrierFailed)" and told him to
  # close a widget he did not have. The slot held a payload written by an older
  # build whose Envelope had a different shape, so the decode failed and an
  # unreadable value was treated as a live exposure. Nothing on the device could
  # clear it. The widget draws through the same decoder, so bytes it cannot decode
  # are bytes it cannot render — they are rubbish, not an exposure.
  Scenario: A widget payload left by an older build does not trap my deletion
    Given the widget slot holds a payload this build cannot read
    When I delete my account
    Then the deletion finishes and the unreadable payload is gone
