Feature: A restored session keeps nothing it cannot account for

  When iOS hands the app back a radio mid-transfer, the bytes still arriving belong to a transfer
  a previous run of the app started. Nothing in this run knows how many there should be. Writing
  them produces a file that looks like a recording, passes its own checksum, and is not the
  recording — and nothing downstream can tell.

  Scenario: Bytes from a previous run are never kept
    Given a transfer a previous run of the app opened
    When the whole payload is offered to be kept
    Then it is refused as belonging to another run
    And nothing was kept

  Scenario: This run's own complete transfer is kept
    Given a transfer this run opened, with the recorder's announced size
    When the whole payload is offered to be kept
    Then it is kept

  Scenario: A payload the recorder never sized is refused
    Given a transfer this run opened, where the announced size was never seen
    When the whole payload is offered to be kept
    Then it is refused for having nothing to check against

  Scenario: A short payload is refused even though its bytes are intact
    Given a transfer this run opened, with the recorder's announced size
    When only part of the payload is offered to be kept
    Then it is refused for weighing less than the recorder said
    And the refusal names both numbers
