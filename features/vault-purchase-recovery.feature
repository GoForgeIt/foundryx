Feature: Buying a Vault never strands me, and tells me what I bought

  Four things went wrong in one real purchase (Nick, 2026-08-13).

  He started checkout, left the app long enough that the browser was gone, came back — and
  landed on the FIRST screen of the purchase funnel, being sold the Vault he was in the
  middle of buying, with no way back into payment. The app knew: a checkout attempt is
  persisted before the browser ever opens. It simply never said so.

  Then he paid $79 and was told "Your Vault is live" and nothing else. That answers who
  can open it, not what changed. It has to say what he can actually do now — and only
  what actually works, because chat through the cell returns 503 and nothing pulls
  recordings off a Pocket.

  And the "Your Vault is live" row in Settings wears a chevron that does nothing at all.
  A chevron is a promise that there is somewhere to go.

  @vault-recovery
  Scenario: an abandoned checkout says so instead of selling me the same Vault again
    Given I started checkout and left the app before paying
    When I come back and the app checks with the server
    Then I am told my payment did not go through
    And I am offered a way to pick up where I left off
    And I am not put back on the first screen of the purchase funnel

  @vault-recovery
  Scenario: picking up where I left off reopens the checkout I already started
    Given I started checkout and left the app before paying
    And I come back and the app checks with the server
    When I pick up where I left off
    Then the browser reopens the checkout I already started
    And I am waiting on my payment again

  @vault-recovery
  Scenario: I can choose a different plan instead of resuming
    Given I started checkout and left the app before paying
    And I come back and the app checks with the server
    When I choose a different plan
    Then I am on the plans screen

  @vault-recovery
  Scenario: a checkout still in flight this session is not called a failed payment
    Given I just closed the checkout browser without paying
    When the app checks with the server
    Then I am waiting on my payment
    And I am not told my payment did not go through

  @vault-recovery
  Scenario: the abandoned checkout is reachable from Settings
    Given I started checkout and left the app before paying
    And I come back and the app checks with the server
    When I open my Vault from Settings
    Then I am told my payment did not go through
    And I am not put back on the first screen of the purchase funnel

  @vault-recovery
  Scenario: checkout always carries the way back into the app
    Given the Vault service hands the app its own checkout page
    When I continue to checkout
    Then the checkout page is told which app link to return to
    And the checkout page is told which checkout attempt this is

  @vault-recovery
  Scenario: a checkout page that already names its own return link keeps it
    Given the Vault service hands the app a checkout page that already names its return link
    When I continue to checkout
    Then the return link the service chose is left alone

  @vault-recovery
  Scenario: a live Vault says what I can do now
    Given my payment is confirmed and my Vault is ready
    When I see that my Vault is live
    Then I am told my recordings now go to my Vault
    And I am told I can search my whole history
    And I am not promised chat with my Vault
    And I am not promised that my Pocket syncs to my Vault

  @vault-recovery
  Scenario: the live Vault row in Settings leads somewhere
    Given my payment is confirmed and my Vault is ready
    When I look at my Vault in Settings
    Then the row leads to my Vault detail
    And the detail tells me my Vault is live
    And the detail tells me what my Vault holds
    And the detail offers me a way to delete my Vault
    And the detail offers me a way back to my phone

  @vault-recovery
  Scenario: a Vault I do not have has no detail to lead to
    Given a free on-device user with no Vault at all
    When I look at my Vault in Settings
    Then the row does not lead to a Vault detail
