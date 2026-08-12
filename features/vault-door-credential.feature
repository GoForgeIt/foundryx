Feature: A ready Vault I cannot open is a visible failure, not a silent one

  Pairing with the Vault needs a door credential. The server issues it; the app
  presents it. When it is missing there is nothing to fall back to — the Vault is
  running and unreachable — and the one thing the app must not do is look like it
  worked.

  That is exactly what shipped. The credential was minted INSIDE the cell, on the
  tenant's own volume, so the signup service had none to send and answered "ready"
  with no way in. The app required it, threw, and the throw landed in the branch
  reserved for network blips. The result was an eternal "Setting up…" while capture
  quietly went back to recording on the phone alone. Nobody noticed for weeks,
  because nothing anywhere said anything.

  Scenario: a ready Vault with no door credential is reported, not swallowed
    Given my payment is confirmed and setup is under way
    When the server says my Vault is ready but sends no door credential
    Then I am told my Vault is running but the app cannot get in
    And I am not left watching setup progress
    And my paid Vault attempt is still remembered

  # One layer up, the same swallow: a 200 whose body this build cannot read at all
  # (a proxy error page, a truncated response) is a contract breach, not a dropped
  # packet, and no amount of waiting fixes it.
  Scenario: an answer this app cannot read is reported rather than waited on
    Given my payment is confirmed and setup is under way
    When the server answers with a body this app cannot read
    Then I am told my Vault is running but the app cannot get in
    And I am not left watching setup progress

  Scenario: a ready Vault WITH its door credential connects
    Given my payment is confirmed and setup is under way
    When the server says my Vault is ready and sends the door credential
    Then the app pairs with the Vault instead of reporting a failure

  # A Vault the OWNER deleted, on an account they kept: there is nothing to connect
  # to and nothing has gone wrong. Rendering that as "something went wrong" would
  # put an error in front of a person whose Vault is simply being rebuilt.
  Scenario: a deliberately deleted Vault is not reported as a fault
    Given my payment is confirmed and setup is under way
    When the server says my Vault was deleted and a new one is on the way
    Then the app keeps waiting quietly rather than showing me an error

  # The return ticket travels through a browser and the OS, so the server withholds
  # the credential on that path deliberately. That is the contract, not a fault — the
  # app must go ask the authenticated endpoint rather than show an error.
  Scenario: the return-ticket path is not treated as a failure for withholding it
    Given my payment is confirmed and setup is under way
    When the return ticket reports my Vault is ready without a door credential
    Then the app treats it as not-yet-answered and asks again with my sign-in
