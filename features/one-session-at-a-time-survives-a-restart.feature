Feature: One session at a time, even when iOS hands the radio back

  The recorder allows one authenticated conversation at a time. When iOS restores the app it
  restores the connection but not the conversation: the recorder still believes the previous run
  is talking to it, and this run knows nothing about that. Writing the key again over that link is
  the one move whose failure is silent — the recorder may quietly re-key and neither end says so.

  Scenario: The app does not talk to a restored recorder until the old link is retired
    Given a link iOS handed back from a previous run
    Then the app may not open a session yet
    And it is told to stop accepting what the old link is sending

  Scenario: Retiring the link is not enough on its own
    Given a link iOS handed back from a previous run
    And the app has stopped accepting what it sends
    Then the app may not open a session yet
    And it is told to drop the half-finished transfer

  Scenario: Once the old link is gone the app may talk again
    Given a link iOS handed back from a previous run
    And the app has stopped accepting what it sends
    And the half-finished transfer is dropped
    And the old link is retired
    Then the app may open a session

  Scenario: A link this run opened needs no reconciling
    Given a link this run of the app opened itself
    Then the app may open a session
