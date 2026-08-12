Feature: Set up a Pocket without weakening the owner's custody
  Pocket setup stays local, preserves an existing maker-app pairing, and teaches physical controls without claiming telemetry.

  Scenario: Factory-fresh setup begins with one plain action
    Given a selected factory-fresh Pocket with authenticated identity components
    When I open Pocket setup
    Then I see one sentence and one Set up button without credential language

  Scenario: A completed setup binds custody to the authenticated composite identity
    Given a selected factory-fresh Pocket with authenticated identity components
    When Pocket accepts the candidate and FoundryX securely stores it
    Then setup completes only after battery and firmware confirmation

  Scenario: A secret cannot be retrieved for a different peripheral
    Given a stored Pocket secret bound to an authenticated composite identity
    When only the CoreBluetooth peripheral identifier is substituted
    Then no Pocket secret is returned

  Scenario: A cold launch restores custody from transport identity alone
    Given only a stored Pocket custody record remains after launch
    When the Pocket reconnects with its transport identity
    Then the stored Pocket secret is retrieved without already possessing it

  Scenario: A prior FoundryX pairing is restored before any fresh write
    Given an already-used Pocket with a matching stored secret
    When I reconnect it
    Then FoundryX submits only the stored secret and preserves the maker-app setup

  Scenario: An owner can keep the maker app
    Given an already-used Pocket without a matching stored secret
    When I ask how to connect it
    Then coexistence is explained as advanced key capture and reset is the last resort

  Scenario: Untrusted identity is quarantined before a credential write
    Given a Pocket with a missing or mismatched identity component
    When I try to set it up
    Then no credential is submitted and the observation is quarantined

  Scenario: A candidate this iPhone cannot store never reaches the device
    Given secure storage that refuses the first attempt
    When I set the Pocket up and then try again
    Then nothing reached the device until custody held the key, and setup completes only then

  Scenario: Indeterminate authentication does not classify ownership
    Given Pocket authentication times out or disconnects
    When setup handles the result
    Then setup stops without offering reset, coexistence, or another credential

  Scenario: Custody surfaces never reveal the session secret
    Given a Pocket secret is in secure custody
    When I inspect setup copy, diagnostics, and available actions
    Then the secret is absent and there is no reveal, copy, share, or export action

  Scenario: Device education is one honest scroll
    Given Pocket setup has completed
    When I open How your recorder works
    Then button, switch, and light guidance appears without claiming detected recording state

  Scenario: Pocket remains pull-after-the-fact
    Given Pocket setup has completed
    When I inspect the onboarding outcome
    Then there is no live capture, recording pill, Live Activity, or current recording state
