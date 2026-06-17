Feature: FoundryX dials the local Foundry door

  The Swift client (FoundryXKit.DoorClient — the M3 app's networking core) opens a
  session in the local Foundry brain (gateway → kiln-session) and streams a completed
  reply; an unauthenticated request is rejected before any session or inference; and the
  routed turn is recorded in the real kiln-session event log. Driven against the REAL
  door + real kiln-session via the Fixture API — no mocks.

  Scenario: an authenticated message opens a session and streams a completed reply
    Given a running Foundry door
    When the client sends an authenticated message "hello"
    Then the door opened a session
    And the reply streams at least one assistant delta
    And the turn ends with done reason "completed"

  Scenario: an unauthenticated request is rejected before any session or inference
    Given a running Foundry door
    When the client sends a message with no bearer token
    Then the door rejects it as unauthorized

  Scenario: the routed turn is recorded in the kiln-session event log
    Given a running Foundry door
    When the client sends an authenticated message "remember this"
    Then the kiln-session event log records a routed turn

  Scenario: the streamed reply renders in the hosted chat view
    Given a running Foundry door
    When the client sends an authenticated message "hello"
    Then the streamed reply renders in a hosted ChatView ending in "completed"
