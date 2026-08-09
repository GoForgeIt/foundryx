Feature: Pocket is a stored-file recording device in the one device list
  Pocket supplies completed recordings after the fact. Its authenticated device identity is
  shared with secure custody, while its friendly name remains presentation only.

  Scenario: Stored-file delivery is usable without becoming a live source
    Given an authenticated stored-file recorder without a live audio profile
    When the recording source catalog evaluates it
    Then it selects stored-file sync and is usable for later file access
    And it is excluded from live source candidates

  Scenario: The shared identity can be reconstructed without the session secret
    Given a provisioned recorder identity and its persisted public lookup components
    When the device list reconstructs the identity without the session secret
    Then its device-list identity and secret-storage key are identical
    And its advertised name is absent from that identity

  Scenario: Authenticated discovery reads Pocket facts through the protocol client
    Given an authenticated Pocket transport reporting battery and firmware
    When the Pocket discovery bridge observes the device
    Then the one device list contains its friendly row with literal battery and firmware
    And offline storage is present without exposing the uncalibrated storage pair

  Scenario: The device page reports link state and never recording state
    Given a connected stored-file recorder with battery and firmware facts
    When the device page presentation is built
    Then its hero reports the link as connected with battery and firmware
    And no recording pill, recording state, or Live Activity surface is present

  Scenario: The storage manifest distinguishes custody and renders bytes as duration
    Given recorder files that FoundryX has and files only on the recorder
    When the storage manifest presentation is built
    Then each recording shows its custody and duration at 32 kilobits per second

  Scenario: A stored-file lifecycle has no live-pipeline effects
    Given spies around every live capture boundary
    When a stored-file device is discovered attached displayed disconnected and reconnected
    Then no active source FrameRouter WAL Live Activity or live state mutation occurs
