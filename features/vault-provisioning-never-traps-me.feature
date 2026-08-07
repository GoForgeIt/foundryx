Feature: Vault provisioning never holds the app hostage

  Provisioning continues on the server after payment. Its status is information, not a
  modal gate: capture stays usable, failures are explained, and Settings remains the
  durable way back.

  Scenario: I can leave while my paid Vault is being provisioned
    Given payment is confirmed and my Vault is being provisioned
    Then I see that setup is still in progress
    And I can keep using FoundryX
    When I keep using FoundryX
    And the app checks Vault status in the background
    Then capture is available
    And my paid Vault attempt is still remembered

  Scenario: provisioning takes longer than expected
    Given payment is confirmed and my Vault is being provisioned
    When the bounded setup wait expires
    Then I am told setup is taking longer than expected
    And I am told I can leave and will be emailed
    And I can keep using FoundryX

  Scenario: a provisioning error reaches the setup screen
    Given payment is confirmed and my Vault is being provisioned
    When provisioning fails because "registry could not create the cell"
    Then I see "registry could not create the cell"
    And I can keep using FoundryX

  Scenario: an existing Vault is explained
    Given payment is confirmed and my Vault is being provisioned
    When provisioning fails because the Vault already exists
    Then I am told I already have a Vault
    And I can return to my notes

  Scenario: I can return to provisioning status from Settings
    Given payment is confirmed and my Vault is being provisioned
    When I keep using FoundryX
    And the app checks Vault status in the background
    And I open Vault status from Settings
    Then I see that setup is still in progress

  Scenario: a successful provision tells the truth
    Given payment is confirmed and my Vault is being provisioned
    When provisioning succeeds
    Then I see that my Vault is live
    And I can enter it

  Scenario: setup progress does not invent server steps
    Given payment is confirmed and my Vault is being provisioned
    Then I do not see decorative per-step progress

  Scenario: a paid owner relaunches while the real provisioning failure persists
    Given a paid Vault attempt is persisted from an earlier build
    And provisioning fails because the Vault already exists
    When I relaunch FoundryX
    Then the working free app is visible
    And I can start an on-device capture
    And Settings shows that I already have a Vault
    And my paid Vault attempt is still remembered
