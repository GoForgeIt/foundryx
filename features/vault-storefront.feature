Feature: US-first storefront gating + in-app account deletion — App-Review-clean

  Track T-STOREFRONT (foundryx-hearth 20260715T0904_vault_storefront_policy). Billing stays
  off Apple's 30% AND the app stays App-Review-clean: the purchase path (plans + external web
  checkout) shows ONLY where the App Store storefront allows it (US-first), gated by StoreKit
  `Storefront` country — NOT IP or locale. Everywhere else is sign-in only, so an existing
  subscriber can still open their Vault, with NO purchase CTA. An unknown storefront FAILS
  CLOSED (no purchase CTA). Apple also requires in-app account deletion, offered three ways:
  erase this phone, delete the hosted Vault, or delete the account everywhere.

  @storefront
  Scenario: a US storefront shows the purchase CTA and can open checkout
    Given a free on-device user whose App Store storefront is the US
    Then the Vault entry shows the purchase CTA
    And turning on the Vault from Settings reaches the plans screen

  @storefront
  Scenario: a non-US storefront shows sign-in only, no purchase CTA
    Given a free on-device user whose App Store storefront is outside the US
    Then the Vault entry shows sign-in only, with no purchase CTA
    And turning on the Vault from Settings does not reach the plans screen

  @storefront
  Scenario: an unknown storefront fails closed with no purchase CTA
    Given a free on-device user whose App Store storefront cannot be determined
    Then the Vault entry shows sign-in only, with no purchase CTA

  @storefront
  Scenario: account deletion offers three scopes and invokes the right seam
    Given a signed-in user on the account-deletion screen
    Then the account-deletion screen offers erase-this-phone, delete-hosted-Vault, and delete-everywhere
    When they choose to delete the hosted Vault
    Then only the hosted-Vault deletion seam is invoked
    When they choose to delete the account everywhere
    Then the delete-everywhere seam is invoked
