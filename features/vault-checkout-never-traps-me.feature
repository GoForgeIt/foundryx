Feature: A Vault checkout never traps me on "Checking your payment"

  Nick paid for a Vault at 14:05 and was still staring at "Checking your payment…" five
  hours later, on every launch, with no way out. The payment had succeeded; provisioning
  had failed server-side; and every single reconcile his phone made returned 401 because
  the funnel signs its requests with a CACHED id_token that nobody refreshes — Google
  expires those after an hour. Each of those three facts was invisible to him, because
  the funnel renders every non-terminal state as the same spinner and swallows every
  error as if it were a passing network blip.

  Waiting is fine. Waiting FOREVER, with no information and no exit, is not. This spec
  says: sign with a live token, tell me the truth when the truth is bad, and always leave
  me a door.

  Scenario: the reconcile is signed with a token that is still valid
    Given my sign-in token expired an hour ago
    When the app checks on my payment
    Then it refreshes my token first
    And the check is signed with the refreshed token

  Scenario: an expired sign-in tells me to sign in again
    Given my sign-in can no longer be refreshed
    When the app checks on my payment
    Then I am told my sign-in expired
    And I am offered a way to sign in again
    And I am not left watching a spinner

  Scenario: a network blip keeps waiting quietly
    Given my payment is still being confirmed
    When the check cannot reach the server
    Then I am still waiting on my payment
    And nothing alarming is shown

  Scenario: a failed provision tells me it failed
    Given provisioning my Vault failed
    When the app checks on my payment
    Then I am told setting up my Vault did not finish
    And I am offered a way to try again
    And I am not left watching a spinner

  Scenario: a suspended Vault is not a spinner
    Given my Vault is suspended
    When the app checks on my payment
    Then I am not left watching a spinner

  Scenario: a status the app does not recognise is never treated as progress
    Given the server reports a status this app has never heard of
    When the app checks on my payment
    Then I am not left watching a spinner

  Scenario: I can abandon a checkout that is going nowhere
    Given I have been waiting on my payment for a long time
    Then I am offered a way to stop waiting
    When I stop waiting
    And I reopen the app
    Then I am not put back into checking my payment

  Scenario: a checkout that failed stops haunting me
    Given provisioning my Vault failed
    When the app checks on my payment
    And I reopen the app
    Then I am not put back into checking my payment

  Scenario: an expired sign-in keeps my checkout so I can resume it
    Given my sign-in can no longer be refreshed
    When the app checks on my payment
    Then my checkout is still remembered

  Scenario: waiting a normal amount of time still just waits
    Given my payment is still being confirmed
    When I reopen the app
    Then I am still waiting on my payment

  Scenario: a confirmed payment still lands my Vault
    Given my payment is confirmed and my Vault is ready
    When the app checks on my payment
    Then my Vault is live
    And I am no longer waiting on my payment
