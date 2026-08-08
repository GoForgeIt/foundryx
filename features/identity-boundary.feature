Feature: Every account-bearing surface changes identity together

  Scenario: Signing out removes the previous account from the widget
    Given I am signed in and my widget shows my account
    When I sign out
    Then the widget shows no account or capture from my previous account

  Scenario: Signing in as another account replaces the widget account
    Given the widget has a capture from my first account
    When I sign out and sign in as a second account
    Then the widget belongs to my second account
    And the first account's capture is not readable from the widget

  Scenario: Finishing old account work cannot reclaim the widget
    Given work started under my old account is still finishing
    When I switch to a new account before that work finishes
    Then the widget shows only my new account after the old work finishes

  Scenario: Deletion removes the account from every surface
    Given my account is present on every account-bearing surface
    And another account owns the widget
    When I delete my account now
    Then deletion completes
    And my deleted account is absent from every erasable surface
    And the other account's widget remains readable

  Scenario: Deleting now removes the device sign-in credential
    Given my account has a saved sign-in credential
    When I delete my account now
    Then no sign-in credential for my deleted account remains on the device

  Scenario: A deleted account can return and be provisioned again
    Given my account deletion completed on this device
    When I sign up again with the deleted account
    Then the account is admitted as a returning account
    And provisioning is requested again

  Scenario: Signing out during an identity change still succeeds
    Given an identity change is in flight
    And my account has a saved sign-in credential
    When I sign out
    Then I am signed out
    And no sign-in credential for my account remains on the device

  Scenario: Signing out ends the previous account's lock-screen capture card
    Given my account has a lock-screen capture card
    When I sign out
    Then no lock-screen capture card from my previous account remains

  Scenario: Signing out suspends the saved Omi pairing
    Given I am signed in with a saved Omi pairing
    When I sign out
    Then my Omi pairing remains available for the next sign-in

  Scenario: Failed sign-out preserves device pairings
    Given I am signed in with device pairings
    And erasing the identity credential will fail
    When I sign out
    Then my account remains signed in
    And my device pairings remain available

  Scenario: A paired recording device cannot cross accounts
    Given my first account paired a recording device
    When I sign out and sign in as a second account
    Then the second account does not reconnect to the first account's recording device
