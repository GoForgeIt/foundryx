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
