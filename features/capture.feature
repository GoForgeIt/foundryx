Feature: FoundryX captures Omi audio durably to the door

  The phone write-ahead-logs Opus frames and uploads them as numbered segments to
  the REAL door's /foundryx/capture; a segment is marked synced ONLY on the door's
  200 ACK (durably stored on the desktop). Unsynced segments persist and retry, so
  a dropped connection never loses audio. Driven via a ReplaySource (no hardware)
  against the real door + Fixture API — no mocks. The real Omi BLE source is a
  separate @ble-hardware lane.

  Scenario: replayed Opus frames are WAL'd and synced to the door
    Given a running Foundry door
    And a capture WAL fed 120 replayed Opus frames
    When the WAL syncs to the door
    Then every segment is acknowledged and marked synced
    And the door has the capture durably stored

  Scenario: re-syncing an already-acknowledged capture is idempotent
    Given a running Foundry door
    And a capture WAL fed 60 replayed Opus frames
    When the WAL syncs to the door
    And the WAL syncs to the door again
    Then every segment is acknowledged and marked synced

  Scenario: segments stay pending when the door is unreachable and drain on reconnect
    Given a running Foundry door
    And the door is unreachable
    And a capture WAL fed 60 replayed Opus frames
    When the WAL syncs to the door
    Then the capture has unsynced segments
    When the door becomes reachable
    And the WAL syncs to the door
    Then every segment is acknowledged and marked synced

  Scenario: manually splitting a conversation finalizes the current one and starts a new one
    Given an ambient capture is recording a conversation
    When I tap to start a new conversation
    Then the current conversation is finalized and sent for transcription
    And a new conversation begins recording immediately without dropping audio

  Scenario: tapping new conversation when nothing is recording does nothing
    Given no ambient capture is recording
    When I tap to start a new conversation
    Then no conversation is finalized and nothing is recording

  Scenario: recording from the phone microphone finalizes through the normal path
    Given the Omi is not connected
    And I am recording a conversation with the phone microphone
    When I stop the phone-microphone recording
    Then the conversation is finalized and sent for transcription like an Omi capture

  Scenario: the phone-microphone Opus matches the pipeline's segment format
    Given a conversation recorded with the phone microphone
    Then its audio is 48 kHz mono Opus in 20 ms frames the door and decoder already accept

  Scenario: a Record control is offered when the Omi is not connected
    Given the Omi is not connected
    Then I can record a conversation with the phone microphone

  Scenario: choosing the phone microphone as the capture source does not auto-connect the Omi
    Given I choose the phone microphone as my capture source
    Then my choice is remembered and the Omi is not auto-connected

  @ble-hardware
  Scenario: a real Omi wearable streams Opus frames into the WAL
    Given a real Omi wearable in range
    When the app connects and subscribes to the audio stream
    Then Opus frames arrive and are written to the WAL
