Feature: A closed recording reaches an honest final state
  A recording must never be finalized until every audio segment is known to be
  durable on the computer. If that cannot happen within the recovery window, the
  phone keeps its audio and shows an explicit incomplete state.

  Scenario: A lost acknowledgement is repaired from the computer's durable manifest
    Given a closed recording has segments waiting for acknowledgement
    And the computer reports that every segment is already durable
    When pending recordings are recovered
    Then the recording is finalized without uploading those segments again

  Scenario: A recording that cannot be recovered becomes visibly incomplete
    Given a closed recording has waited beyond the recovery window
    And some segments are still only on the phone
    When pending recordings are recovered
    Then the recording is marked incomplete with the unrecovered segment count
    And its audio remains on the phone
    And it is not finalized
    And the recording card says "Incomplete — audio kept on this phone"

  Scenario: I can retry an incomplete recording after the recovery window expired
    Given an incomplete recording has waited beyond the recovery window
    And its segments are still only on the phone
    When I choose "Send to computer"
    Then the card says the recording is being sent
    And the expired recovery window does not stop the upload
    And the recording finalizes through the normal path

  Scenario: A failed manual recovery remains safely retryable
    Given an incomplete recording has waited beyond the recovery window
    And the computer cannot accept its segments
    When I choose "Send to computer"
    Then the recording returns to incomplete with the failure reason
    And its audio remains on the phone
    And I can choose "Send to computer" again
    And the failed recovery outcome is written to diagnostics

  Scenario: Repeated recovery skips audio already durable on the computer
    Given an incomplete recording has waited beyond the recovery window
    And the computer already holds some of its segments
    When I choose "Send to computer" repeatedly while other recordings sync
    Then only the outstanding segments are uploaded once
    And the recording finalizes through the normal path
