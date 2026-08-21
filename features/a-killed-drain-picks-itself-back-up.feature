Feature: A killed drain picks itself back up

  Everything else about surviving a restart is a refusal: don't take those bytes, don't keep that
  file, don't talk over that link. All of it together, and nothing more, is an app that handles
  being killed perfectly and never brings a recording over again.

  This is the other half. After the wreckage is cleared and the recorder is talking to us again,
  the recordings that were waiting come over — from the beginning, without anybody tapping
  anything.

  Scenario: The recordings that were waiting come over after a restart
    Given a drain that was killed with two recordings still waiting
    When the app recovers from the restart
    Then both recordings come over
    And nobody had to tap anything

  Scenario: The recovery happens in the order that keeps the recorder honest
    Given a drain that was killed with two recordings still waiting
    When the app recovers from the restart
    Then it stops listening to the old link before anything else
    And it drops the half-finished file before retiring the link
    And it retires the link before talking to the recorder again

  Scenario: The wreckage is cleared on the way through
    Given a drain that was killed with two recordings still waiting
    And a half-file left behind by the transfer that was interrupted
    When the app recovers from the restart
    Then the half-file is gone

  Scenario: A recovery that only got some of them says so
    Given a drain that was killed with two recordings still waiting
    And the recorder will only give back one of them
    When the app recovers from the restart
    Then it reports that it did not get everything it tried for

  Scenario: A restart with nothing waiting is not a failure
    Given a drain that was killed with nothing waiting
    When the app recovers from the restart
    Then nothing comes over
    And that counts as having recovered everything it tried for
