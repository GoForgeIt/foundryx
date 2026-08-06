Feature: An interrupted deletion never locks me out of my own app

  Scenario: An unfinished deletion cleans itself up and lets me in
    Given a deletion record exists for my account that never finished
    When I sign in with that account
    Then the local cleanup is completed
    And I am signed in

  Scenario: The app sign-in activation chokepoint finishes an interrupted deletion
    Given the app sign-in path finds an unfinished deletion for my account
    When the app begins account activation for my sign-in
    Then the activation chokepoint completes the local cleanup
    And account activation is allowed to continue

  Scenario: A signed-out owner resumes a cleanup-pending deletion through sign-in
    Given I am signed out with a cleanup-pending deletion for my account
    When the real sign-in persistence path saves my verified identity
    Then the pending deletion cleanup completes
    And the sign-in refusal diagnostic does not report cleanupPending

  Scenario: The app sign-in chokepoint diagnoses a genuine cleanup failure
    Given the app sign-in path finds an unfinished deletion for my account
    And cleanup at the activation chokepoint will fail
    When the app begins account activation for my sign-in
    Then account activation is refused with a typed cleanup error
    And the sign-in diagnostics identify cleanup failure

  Scenario: A cleanup that genuinely fails still refuses, with a reason
    Given a deletion record exists for my account that never finished
    And the local cleanup cannot complete
    When I sign in with that account
    Then I am not signed in
    And I am told why

  Scenario: A completed deletion is unaffected
    Given a deletion record for my account is already completed
    When I sign in with that account
    Then I am signed in

  Scenario: An unreadable deletion state still refuses
    Given the deletion state for my account cannot be read
    When I sign in with that account
    Then I am not signed in
