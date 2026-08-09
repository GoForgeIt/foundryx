Feature: A paid Vault return recovers truthfully

  A successful browser checkout must converge to a ready Vault. Failures checking that
  result must remain distinguishable from an expired sign-in, and Settings must never
  turn an unknown paid entitlement into an unentitled waitlist state.

  Scenario: browser return refreshes authentication and finishes paid Vault setup
    Given I paid for a Vault in the browser
    And the sign-in credential cached before leaving the app is stale
    When I return to the app from checkout
    Then the app refreshes my sign-in credential before reconciling
    And my Vault converges to ready

  Scenario: a rejected reconcile does not create an identical sign-in loop
    Given the Vault server rejects my reconcile for a reason other than credential expiry
    When the app handles the rejection
    Then I am told the Vault status check was rejected
    And I am not told that my sign-in expired
    And I am not offered an identical sign-in retry

  Scenario: Settings preserves unknown entitlement and exposes Vault setup status
    Given I paid for a Vault
    And the app cannot currently determine my entitlement
    And my Vault setup still needs attention
    When I open Settings
    Then my Vault entitlement is shown as temporarily unknown
    And I do not see the Vault waitlist
    And I see the current Vault setup status

  Scenario: completed deletion cleanup has no retry affordance
    Given my previous account deletion cleanup completed successfully
    When the sign-in recovery status is shown
    Then I see that cleanup completed
    And I do not see a cleanup retry control
