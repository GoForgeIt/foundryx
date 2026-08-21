Feature: A bring-over is a queued job with real progress, not a field on a page
  The recorder holds a backlog and the radio carries one file at a time — that is hardware.
  What is not hardware is everything this feature holds: the transfers form a SEQUENTIAL queue
  on ONE authenticated session (measured possible on fw 1.6: two downloads, one subscription,
  no re-auth), each row's progress is denominated in the recorder's own MCU&U& announcement and
  never in the listing (a different unit, measured: listing 4 -> 19,770 bytes), only a stop or
  losing the device ends a transfer, a lost device is retried on the shipped exponential
  backoff, and every retry says out loud that it starts again from the beginning — because the
  wire admits no offset and custody keeps no partial, so a resume would be a lie.

  The chunk lengths and gaps in these scenarios are replayed from
  `Tests/FoundryXBrineTests/fixtures/pocket/pocket-fw16-ble-download-trace.json`, captured on
  2026-08-18 from PKT01_BLUE_26079bc5 on firmware 1.6.

  Scenario: A queue of two empties on one session, with progress that never invents a byte
    Given a recorder holding two recordings queued for transfer, replaying the captured trace
    When the queue runs
    Then both recordings arrive on a single authenticated session
    And each recording's progress climbs to exactly the announced total and never past it
    And the denominator is the announced byte count, never the listed size

  Scenario: Stopping one recording keeps nothing, and the rest of the queue still arrives
    Given a recorder holding two recordings queued for transfer, replaying the captured trace
    When the first recording is stopped partway through
    Then the stopped recording leaves no partial file and no conversation
    And the other recording still arrives whole on a fresh session
    And the stopped recording is not offered to the queue again

  Scenario: A recorder that leaves mid-transfer earns backoff, and every retry starts from zero
    Given a recorder that drops the link partway through a transfer and stays away
    When the queue runs
    Then the waits between retries follow the shipped backoff schedule
    And every retry wait says the transfer starts again from the beginning
    And the recording ends reported as not brought over, with nothing kept

  # AC13, unheld until 2026-08-21. The queue's own progress callback fires once per BLE
  # notification — deliberately, so readings reach the screen in arrival order. What keeps that
  # from being a performance defect is the read model's admission rule, and nothing held it.
  # This repo has a felt-performance proposal that exists because of exactly this shape.
  Scenario: A long transfer does not tell the screen about every chunk that arrives
    Given a transfer that delivers two thousand chunks of a large recording
    Then the screen is told about fewer than one chunk in ten
    And the screen is still told enough times for a bar to move

  # AC2, the paired existence for AC1, unheld until 2026-08-21. AC1 asserts that a queue of two
  # opens exactly ONE authenticated session. That tells you a queue which CAN authenticate works;
  # it says nothing about a queue that cannot. Without this half, AC1 is satisfiable by a harness
  # that has no way to express a refusal — and this repository has a law about exactly that.
  Scenario: A recorder that will not accept the key this phone holds brings nothing over
    Given a recorder holding two recordings that refuses the key this phone holds
    When the queue runs
    Then nothing arrived and nothing was kept
    And no partial file was left behind
