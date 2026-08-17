Feature: Pocket Fast sync is one tap and evidence honest

  Scenario: setup and Settings always show Fast sync
    Given all Pocket WiFi evidence gates are absent
    When Pocket setup and device Settings are presented
    Then both entry points show Fast sync and state that the phone leaves its normal network

  Scenario: joining uses the password the recorder itself reported
    Given an authenticated Pocket identity and a recorder reporting its own network password
    When I select Join and fast sync once
    Then the join receives the network and the password the recorder reported, without showing or logging either secret

  Scenario: a recorder reporting a password this phone would not have guessed is still ours
    Given a recorder reporting the password measured on real hardware
    When I select Join and fast sync once
    Then the recorder is recognised as ours and the join uses what it reported

  Scenario: a recorder holding somebody else's key is still refused
    Given a recorder reporting a password from another owner's key
    When I select Join and fast sync
    Then no network join occurs and the attempt names the credential as the reason

  Scenario: the phone joins while the recorder is waiting for it
    Given a recorder that only says it is ready once a phone has joined
    When I select Join and fast sync once
    Then the phone joined before the recorder was asked whether it was ready
    And the recorder was allowed at least ninety seconds to become ready

  Scenario: a recorder that never becomes ready ends in words rather than a wait
    Given a recorder that never says it is ready
    When I select Join and fast sync
    Then the attempt finishes with a named reason and the recorder is put back on Bluetooth

  Scenario: a network that serves no file is a legible outcome, not a hang
    Given a recorder whose file endpoint answers nothing
    When I select Join and fast sync
    Then nothing is kept, the attempt finishes with a named reason, and the recorder is put back on Bluetooth

  Scenario: nothing this surface can say promises a speed
    Given every line the Fast sync surface can render
    When the lines are read
    Then there is at least one, and none of them names a speed, a multiple, or how long it will take

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
