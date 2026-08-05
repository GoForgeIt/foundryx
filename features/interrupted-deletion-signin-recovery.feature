Feature: An interrupted deletion never locks me out of my own app

  Scenario: An unfinished deletion cleans itself up and lets me in
    Given a deletion record exists for my account that never finished
    When I sign in with that account
    Then the local cleanup is completed
    And I am signed in

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
