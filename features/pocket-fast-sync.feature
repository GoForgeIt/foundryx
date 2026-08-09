Feature: Pocket Fast sync is one tap and evidence honest

  Scenario: setup and Settings always show Fast sync
    Given all Pocket WiFi evidence gates are absent
    When Pocket setup and device Settings are presented
    Then both entry points show Fast sync and state that the phone leaves its normal network

  Scenario: joining uses the already-held credential
    Given an authenticated Pocket identity and matching recorder credentials
    When I select Join and fast sync once
    Then the join receives the reported network and first eight session-key characters without showing or logging either secret

  Scenario: network cost is shown before consent
    Given the Fast sync sheet is open
    When I keep using Bluetooth
    Then no network join occurs and the internet-loss warning was already visible

  Scenario: identity and credential disagreement fail closed
    Given a mismatched Pocket identity or recorder password
    When I select Join and fast sync
    Then no WiFi command, network join, HTTP request, or durable handoff occurs

  Scenario: missing evidence gates completion, not existence
    Given the endpoint, stock-control, and iOS-AP evidence gates are absent
    When I select Join and fast sync
    Then Fast sync remains visible and finishes with a named unavailable gap

  Scenario: a provenance-bearing endpoint can hand one verified file to T4
    Given production evidence gates and a complete selected-file response
    When Fast sync runs the typed authenticated control and HTTP boundaries
    Then exactly one verified completed payload reaches Pocket durable sync

  Scenario: progress has no unsupported speed promise
    Given a backlog of 23 files with 9 durably imported
    When Fast sync progress is presented without measured rate evidence
    Then it shows 9 of 23 with Over, Now, and Waiting and no speed or ETA claim

  Scenario: all exits preserve Pocket invariants
    Given active Fast sync attempts that complete, pause, cancel, fail, and retry
    When each attempt exits
    Then cleanup is attempted, partial bytes never complete, no file is deleted, and no live capture path is reached
