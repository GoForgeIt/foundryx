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

  Scenario: the Omi connect control is a compact icon in the capture header
    Given the Omi is not connected
    Then the capture header shows the Omi as a small icon next to the mic record control

  Scenario: tapping the Omi icon starts a scan and the icon expands
    Given the Omi is not connected
    When I tap the Omi icon in the capture header
    Then a scan for my Omi begins
    And the Omi control expands to show "Scanning…" with an activity indicator

  Scenario: tapping the scanning Omi control stops the scan and collapses it
    Given the capture header is scanning for my Omi
    When I tap the Omi control again
    Then the scan stops and the control collapses back to its compact icon

  Scenario: choosing the phone microphone as the capture source does not auto-connect the Omi
    Given I choose the phone microphone as my capture source
    Then my choice is remembered and the Omi is not auto-connected

  Scenario: a real silence gap splits the ambient stream into two conversations
    Given an ambient capture is recording a conversation
    And the conversation has accumulated real spoken content
    When the audio goes quiet for longer than the silence gap even though no frames are arriving
    Then the current conversation is finalized and sent for transcription
    And a new conversation begins for the next audio

  Scenario: a runaway conversation is force-split by the hard duration cap
    Given an ambient capture has been recording one conversation past the maximum duration
    When the segmentation watchdog next checks the conversation
    Then the conversation is finalized and a fresh one begins so nothing accumulates for hours

  Scenario: a very short noise burst does not become its own conversation
    Given an ambient capture records only a one or two word burst
    When the audio goes quiet for longer than the silence gap
    Then no new tiny conversation is created
    And the burst merges into the next conversation instead

  Scenario: every finalized conversation has real start and end bounds
    Given a conversation is finalized by a silence gap or a forced split
    Then the conversation records an ended-at time so it has real bounds

  Scenario: a conversation orphaned by a crash is bounded and finalized on next launch
    Given a capture has recorded audio but was never finalized before the app closed
    When the app launches again
    Then the orphaned capture is given an ended-at time and queued for finalize

  Scenario: empty and filler conversations are hidden from the list
    Given a conversation whose transcript is empty or only silence filler like "Thank you"
    Then it is not shown in the conversation list
    But its data is kept on the phone

  Scenario: one capture appears as exactly one row in the list
    Given the conversation list holds a capture
    Then that capture is shown as exactly one entry, never duplicated

  Scenario: pausing capture remembers the choice durably
    Given an ambient capture is recording a conversation
    When I pause the capture
    Then my capture is remembered as paused

  Scenario: resuming capture remembers the choice durably
    Given an ambient capture is paused
    When I resume the capture
    Then my capture is remembered as listening

  Scenario: a paused capture stays paused after the app restarts and the Omi reconnects
    Given I previously paused the capture and fully restarted the app
    When the Omi reconnects
    Then capture stays paused and no audio is recorded until I resume

  Scenario: resuming after a paused restart begins recording into the connected session
    Given I previously paused the capture and fully restarted the app
    And the Omi has reconnected and stayed paused
    When I resume the capture
    Then audio is recorded again

  Scenario: a listening capture resumes automatically after the app restarts and the Omi reconnects
    Given I was listening when I fully restarted the app
    When the Omi reconnects
    Then ambient capture resumes automatically and audio is recorded

  Scenario: on first-ever launch capture defaults to listening
    Given I have never set a capture preference
    When the Omi connects for the first time
    Then ambient capture is listening and audio is recorded

  @ble-hardware
  Scenario: a real Omi wearable streams Opus frames into the WAL
    Given a real Omi wearable in range
    When the app connects and subscribes to the audio stream
    Then Opus frames arrive and are written to the WAL
