Feature: Deleting my account tells me the truth about why it failed

  Nick tried "Delete your account everywhere" and got "Check your connection and try
  again." His connection was fine. The gateway was up and answering. No delete request
  ever reached it, because the app signs that call with a CACHED id_token snapshot taken
  at the last session resolve — and when that snapshot is stale or nil the guard throws
  before any HTTP call is made. Every cause then renders as the same sentence: a missing
  token, an expired one the server rejects, and a genuinely dropped connection are
  indistinguishable, and only one of the three is fixed by checking your connection.

  This is the same shape as the Vault checkout trap: a short-lived credential read from a
  cache nobody refreshes, and an auth failure wearing a network failure's clothes.

  Scenario: the delete is signed with a token that is still valid
    Given my cached sign-in token is stale
    When I delete my account everywhere
    Then the app refreshes my token first
    And the delete is signed with the refreshed token

  Scenario: an expired sign-in says so, and does not blame my connection
    Given my sign-in can no longer be refreshed
    When I delete my account everywhere
    Then I am told my sign-in expired
    And I am not told to check my connection
    And nothing was deleted

  Scenario: the server rejecting my sign-in is not a connection problem
    Given the server rejects my sign-in
    When I delete my account everywhere
    Then I am told my sign-in expired
    And I am not told to check my connection

  Scenario: a real network failure still says check your connection
    Given the server cannot be reached
    When I delete my account everywhere
    Then I am told to check my connection

  Scenario: a successful delete still erases everything
    Given my sign-in is valid
    When I delete my account everywhere
    Then the account is deleted on the server
    And this account's local data is erased

  Scenario: a deletion the server cannot do says so, and does not blame my connection
    Given the server has no deletion route
    When I delete my account everywhere
    Then I am told it isn't available yet
    And I am not told to check my connection
    And nothing was deleted

  Scenario: an expired sign-in returns me to the front door
    Given my sign-in can no longer be refreshed
    When I delete my account everywhere
    Then the app signs me out so I can sign in again

  Scenario: a burst of rejections signs me out once
    Given my sign-in can no longer be refreshed
    When several requests are rejected at once
    Then the app signs me out exactly once
