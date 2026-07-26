Feature: My Vault pairing belongs to my account, secret included

  The cell/door pairing record — its address, its auth mode and its bearer — is
  one thing, and it belongs to the person who paired it. A second account on the
  same phone must not inherit it, must not be able to read its secret, and must
  not destroy it by pairing their own.

  These scenarios stage and read REAL Keychain items, so they run only where the
  host can use the Keychain. The iOS unit-test bundle has no keychain entitlement
  (every SecItem call returns errSecMissingEntitlement, -34018), so the suite that
  drives this feature skips wholesale there rather than passing vacuously — and a
  companion guard fails if that skip ever happens on macOS, where it does work.


  Scenario: a second account cannot inherit the first account's Vault pairing
    Given the first account paired a Vault with a private bearer
    When the second account signs in on the same phone
    Then the second account has no Vault cell pairing
    And the second account cannot read the first account's Vault bearer


  Scenario: pairing a Vault preserves every other account's bearer
    Given the first account paired a Vault with a private bearer
    When the second account pairs a different Vault
    And the first account signs back in
    Then the first account's Vault pairing and bearer are intact


  Scenario: a switched account never inherits the prior Vault entitlement
    Given the first account's Vault entitlement router is live
    When the second account signs in without a Vault
    Then the Vault entitlement router shows the second account is off


  Scenario: the current pairing is carried into its owner's account
    Given a Vault and Door pairing exist from before account scoping
    When the verified owner activates account-scoped private data
    Then the owner's Vault and Door pairing remain intact
    And a later account cannot claim either legacy pairing


  Scenario: the free tier never claims a prior account's pairing
    Given a Vault and Door pairing exist from before account scoping
    When FoundryX remains signed out for free on-device use
    Then the free tier has no Vault or Door pairing
    And the unclaimed pairing remains available for its verified owner
