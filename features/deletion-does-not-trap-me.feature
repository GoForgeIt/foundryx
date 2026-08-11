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

  # The OTHER half of the same trap, and the one Nick was actually sitting in.
  # Deletion destroys the server side first, so by the time the erase stops
  # half-way the account no longer exists on the server. "Retry deletion" re-ran
  # the whole thing from the top — server call first — and the server answered
  # "no such account", which the app reports as a missing route and returns
  # BEFORE the only thing still left to do: erasing this iPhone. Every tap did
  # the same nothing.
  Scenario: Retrying a half-finished deletion finishes erasing this iPhone
    Given my account is already deleted on the server and the erase stopped half-way
    When I retry the deletion
    Then this iPhone is erased
    And the server is not asked to delete the account again
    And the deletion finishes

  Scenario: Retrying does not ask a server that no longer has my account
    Given my account is already deleted on the server and the erase stopped half-way
    And the server answers that there is no such account
    When I retry the deletion
    Then this iPhone is erased
    And the deletion finishes

  # A retry button that provably cannot succeed is worse than no button.
  Scenario: A deletion that never reached the server is not offered a pointless retry
    Given the deletion never reached the server because the route is missing
    Then I am not offered a way to try again
    And I am told to erase this iPhone's data instead
