Feature: The drain survives being killed

  A person empties their recorder and walks away. iOS terminates the app — for memory, for an
  update, because it felt like it. Today everything the queue knew is gone: the backlog, the
  attempt counts, and the recordings the owner explicitly STOPPED. The stops are the ones that
  matter, because a forgotten stop does not fail quietly; it hands the recording back to the queue
  and starts pulling it again. `PocketTransferJob`'s own comment calls those stops "durably
  suppressed" while holding them in a `Set` that dies with the process.

  Scenario: The backlog is still there after the app is killed
    Given a recorder with three recordings queued to come over
    When the app is killed and started again
    Then all three are still waiting, in the same order

  Scenario: A recording the owner stopped is not offered again
    Given a recorder with three recordings queued to come over
    And the owner stops the second one
    When the app is killed and started again
    Then the stopped recording is not offered
    And the other two are still offered

  Scenario: What a recording has already tried is remembered
    Given a recorder with three recordings queued to come over
    And the first one has already failed twice
    When the app is killed and started again
    Then that recording has spent two of its attempts

  Scenario: A backlog that cannot be read stops the drain rather than guessing
    Given a recorder whose saved backlog is corrupt
    Then nothing is offered to drain
    And the reason is stated rather than read as an empty queue

  Scenario: A recorder that has never been drained is not an error
    Given a recorder with no saved backlog
    Then nothing is offered to drain
    And that is not reported as a failure
