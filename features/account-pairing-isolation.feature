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


  Scenario: a cold pairing read never stalls an account change
    Given my account already owns a Vault and Door pairing
    And FoundryX has not loaded that pairing in this launch
    When an account change and pairing refresh happen at the same time
    Then the account change completes without waiting for pairing maintenance
    And no existing or legacy pairing is claimed or changed


  Scenario: a failed bearer replacement keeps the prior Vault pairing whole
    Given the first account paired a Vault with a private bearer
    When securely saving a replacement Vault bearer fails
    Then the current session keeps using the original complete Vault pairing
    And reopening FoundryX restores that same complete Vault pairing


  Scenario: a failed unpair keeps one coherent Vault pairing
    Given the first account paired a Vault with a private bearer
    When securely removing that Vault bearer fails
    Then FoundryX reports that the Vault could not be unpaired
    And the current session and a reopened app both retain the original pairing


  Scenario: a failed Door save remains visible and preserves the working Door
    Given my account has a working saved Door connection
    When I save a replacement Door connection and its bearer cannot be stored
    Then the connection screen tells me the replacement was not saved
    And the current session and a reopened app both retain the working Door


  Scenario: a delayed sign-in token restores the new account's Vault
    Given the second account owns a Vault pairing that uses its sign-in
    And its refreshed sign-in token is not ready when the account changes
    When the second account's refreshed sign-in token becomes available
    Then the second account's Vault becomes live
    And the first account's Vault never reconnects


  Scenario: changing to sign-in authentication never leaves a stale bearer
    Given my account paired a Vault with a private bearer
    When I change that Vault to use my sign-in but its old bearer cannot be removed
    Then FoundryX reports that the authentication change did not complete
    And the current session and a reopened app both retain the original pairing
