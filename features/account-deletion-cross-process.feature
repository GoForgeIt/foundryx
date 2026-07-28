Feature: Deleting an account stops work already running elsewhere

  Deleting an account has to reach work that is ALREADY in flight, including in
  another process. A producer that captured its authorization a moment ago must
  not get to publish after the deletion is durably recorded.

  This scenario spawns a real second process, so it runs only where the test host
  can do that. An iOS unit-test bundle cannot, so the suite driving this feature
  skips wholesale there rather than reporting a vacuous pass — and a companion
  guard fails if that skip ever happens on macOS, where it does work.

  Scenario: pending deletion revokes account work cached in another process
    Given another process has captured work for the signed-in account
    And that process retains unsaved audio and chat changes for the account
    When this process durably marks that account pending deletion
    Then the other process rejects the captured work before it can publish
    And account storage access in the other process fails closed
    And retained audio and chat changes cannot recreate the deleted account storage
    And the captured account binding is no longer current in the other process
