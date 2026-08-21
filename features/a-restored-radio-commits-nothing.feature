Feature: A restored radio commits nothing the app cannot account for

  iOS can hand an app back a Bluetooth peripheral that is still connected and still subscribed,
  in the middle of a file transfer the previous run of the app started. The link survives; the
  protocol client, the byte meter and the writer that owned the half-written file do not. Chunks
  then arrive belonging to a transfer this process never opened, with no way to know what they
  are or how many should follow.

  Those bytes must never become a recording. A person would see a file that looks complete and is
  not, and nothing downstream could tell the difference.

  Scenario: Bytes from a transfer this app never opened are refused
    Given a transfer opened by a previous run of the app
    When the restored radio delivers a chunk
    Then the chunk is refused as belonging to another run
    And the refusal says which run it came from

  Scenario: Bytes from this app's own transfer are accepted
    Given a transfer this run of the app opened
    When the radio delivers a chunk
    Then the chunk is accepted

  Scenario: A delivery with no transfer open is refused for that reason
    Given no transfer is open
    When the radio delivers a chunk
    Then the chunk is refused for having no transfer to belong to

  Scenario: After a restoration is reconciled the app can transfer again
    Given a transfer opened by a previous run of the app
    When the restoration is reconciled
    And this run opens a transfer and the radio delivers a chunk
    Then the chunk is accepted
    And the previous run's chunks are still refused
