Feature: An unfinished deletion does not lock me out of my own account
  Deleting an account destroys the server side first and erases this phone second.
  When the erase is refused half-way, the device keeps a `cleanupPending` record —
  and signing back in with that same account then fails, because returning to
  half-erased data is exactly what that record exists to prevent.

  But the refusal was silent and total. The person is returned to the login screen
  with no message, and the ONLY way to clear the pending cleanup is the "Retry
  deletion" button in Settings — which requires being signed in, which is what is
  blocked. Their server account is already gone, so there is no other way back.

  That is a trap, and it happened for real on 2026-08-02.

  # Signing in is a COMMAND. These pin what it TELLS the person and what it does
  # to the pending record — a check that only read "am I signed in?" would call
  # the silent bounce a correct refusal.
  Scenario: I am told why my sign-in was refused
    When I sign in with an account whose deletion never finished
    Then I am told the deletion did not finish
    And I am not simply returned to the login screen with no explanation

  Scenario: I am offered a way out without signing in first
    When I sign in with an account whose deletion never finished
    Then I am offered to finish the deletion

  Scenario: Finishing the deletion lets me start fresh
    When I finish the interrupted deletion from the login screen
    Then the pending record is resolved
    And I can sign in with that account again

  Scenario: A refused sign-in does not quietly return me to half-erased data
    When I sign in with an account whose deletion never finished
    Then I am not signed in

  Scenario: An account with no deletion history signs in normally
    When I sign in with an account that was never deleted
    Then I am signed in
    And I am not told anything about a deletion
