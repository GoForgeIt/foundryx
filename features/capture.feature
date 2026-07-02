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

  # Source connection is automatic + self-healing: the capture page auto-connects to the
  # saved Omi and auto-reconnects on a drop. The user never hand-drives a BLE scan from
  # here — only first-time pairing (no saved device) surfaces a tap-to-connect.

  Scenario: the capture page surfaces an inline connect affordance when nothing is connected
    Given the Omi is not connected and nothing is being captured
    Then the capture page shows an inline "Connect your Omi" affordance

  Scenario: a dropped Omi link reconnects automatically without the user driving a scan
    Given the Omi link has dropped
    Then the capture page shows an auto-reconnecting status and no scan control

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

  Scenario: a sub-substance fragment is never uploaded to the door
    Given an ambient capture records only a brief silent or one-word fragment
    When the conversation ends
    Then the fragment is kept on the phone but never uploaded to the door
    And it is not shown in the conversation list

  Scenario: a real conversation clears the substance bar and is uploaded
    Given an ambient capture records a conversation with real spoken content
    When the conversation ends
    Then the conversation is finalized and sent for transcription

  Scenario: a transient Omi disconnect resumes the same conversation instead of fragmenting it
    Given an ambient capture is recording a conversation
    When the Omi link briefly drops and reconnects within the grace window
    Then recording resumes into the same conversation
    And no new conversation or upload stub is created

  Scenario: an Omi disconnect that stays down ends the conversation after the grace window
    Given an ambient capture is recording a conversation
    When the Omi link drops and does not reconnect within the grace window
    Then the conversation ends and is finalized like a normal boundary

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

  Scenario: only actual conversations are uploaded — ambient noise is not
    Given ambient capture is listening
    When a long stretch of background noise with no real speech is captured
    Then that capture is dropped locally and never uploaded to the door

  Scenario: a real spoken exchange is uploaded even if it is brief
    Given ambient capture is listening
    When I have a short spoken exchange that transcribes to real words
    Then that conversation is finalized and uploaded

  Scenario: a long conversation is kept even when on-device transcription is unavailable
    Given a device without on-device transcription
    When I have a long spoken conversation
    Then that conversation is finalized and uploaded on the voiced-audio signal alone
