Feature: The wreckage of a killed transfer is cleared

  A transfer writes arriving bytes to a half-file beside the real one and only takes the real name
  once the bytes have been read back and checked. That is why a killed transfer never produces a
  recording that looks complete and is not. What it does produce is a half-file nobody will ever
  finish, because a retry starts from the beginning — and until now nothing ever removed one.

  Scenario: A half-file from a previous run is cleared away
    Given a half-file left behind by a transfer that was killed
    When the app starts and clears the wreckage
    Then the half-file is gone
    And the report names what it removed

  Scenario: The half-file being written right now is not touched
    Given a half-file left behind by a transfer that was killed
    And a transfer that is writing its own half-file right now
    When the app clears the wreckage
    Then the half-file being written is still there
    And the abandoned one is gone

  Scenario: A finished recording is never mistaken for wreckage
    Given a recording that came over completely
    When the app starts and clears the wreckage
    Then the recording is still there

  Scenario: A recorder with nothing to clear reports nothing
    Given no half-files anywhere
    When the app starts and clears the wreckage
    Then nothing was removed
