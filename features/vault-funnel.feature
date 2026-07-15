Feature: A free user activates a Vault and lands in it — the funnel spine

  Track T-IOS-FUNNEL (foundryx-hearth 20260715T0903_vault_ios_funnel). The free app is
  on-device only. A paid-intent action guides the user to turn on their Vault, hands off to
  an external browser for login + payment, and returns via SERVER RECONCILIATION (not the
  deep link): a checkout attempt is persisted before the browser opens, and entitlement is
  reconciled on every foreground. The server is authoritative — a dismissed browser is not a
  failure. When the Vault is live it is handed to the same CellBackend the app drives.

  @funnel
  Scenario: a paid-intent trigger with no Vault routes to the Vault trigger
    Given a free on-device user with no Vault
    When they tap a Vault-only action
    Then they are routed to the Vault trigger, not a dead end
    And the trigger can start Vault setup

  @funnel
  Scenario: the plans CTA persists a checkout attempt before opening the browser
    Given a free on-device user on the plans screen
    When they continue with a plan
    Then a checkout attempt is persisted before the browser opens
    And the browser opens to the checkout for that plan

  @funnel
  Scenario: returning with a verified payment reconciles to a live Vault
    Given a free on-device user who completed browser checkout
    When the app reconciles on return with a verified payment
    Then the app provisions and connects the Vault
    And the connected Vault is handed to the app's cell backend

  @funnel
  Scenario: a dismissed browser without payment stays checking and reconciles later
    Given a free on-device user who dismissed the browser without paying
    Then the funnel is checking payment, not failed
    When the payment clears and the app reconciles on the next foreground
    Then the Vault becomes live

  @funnel
  Scenario: provisioning shows a durable setting-up state before live
    Given a free on-device user whose payment is confirmed but the cell is still provisioning
    When the app reconciles on foreground
    Then the funnel is setting up the Vault
    And a later reconcile brings the Vault live

  @funnel
  Scenario: routing respects entitlement once the Vault is live
    Given a user with a live Vault
    When they tap a Vault-only action
    Then they are routed into the Vault, not the trigger

  @funnel
  Scenario: a returning free user with no attempt is not dragged into the funnel
    Given a returning free on-device user with no checkout attempt
    When the app reconciles on foreground
    Then the funnel stays idle

  @funnel
  Scenario: the Settings entry launches the funnel when the Vault is off
    Given a free on-device user with no Vault
    When they turn on their Vault from Settings
    Then the funnel begins Vault setup

  @funnel
  Scenario: the Settings entry reflects a live Vault instead of re-launching setup
    Given a user with a live Vault
    When they turn on their Vault from Settings
    Then the Settings entry does not launch the funnel
