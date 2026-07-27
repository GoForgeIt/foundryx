Feature: Omi always reconnects and syncs its offline cache

  When I walk away from my phone with my Omi on, the link drops. I should never
  have to open the app to get it back: the phone keeps a standing (pending)
  reconnect that completes the moment the Omi is back in range — even while the
  app is in the background, and even if iOS killed the app in the meantime. And
  whatever the Omi recorded on its own storage during the gap is pulled over and
  joins my conversation, in the order it was spoken.

  Scenario: the link drops out of range and a reconnect is armed immediately
    Given my Omi is connected and I walk out of Bluetooth range
    When the link drops
    Then a pending reconnect to my Omi is issued immediately
    And the reconnect waits for the Omi to return without any scanning loop

  Scenario: a failed connect attempt retries instead of giving up
    Given my Omi is reconnecting
    When the connect attempt fails
    Then another reconnect attempt is scheduled shortly after

  Scenario: an Omi I toggled off stays disconnected
    Given I turned my Omi off on the device page
    When the link drops
    Then no reconnect is issued until I re-enable it

  Scenario: the app relaunches in the background when the Omi returns
    Given iOS terminated the app while a pending reconnect was waiting
    When the Omi comes back into range
    Then the app is relaunched in the background and re-adopts the Omi link
    And the audio that streams in is saved durably on the phone without opening the app

  Scenario: audio recorded during the gap is pulled from the Omi's storage
    Given my Omi recorded audio to its onboard storage while disconnected
    When the Omi reconnects
    Then the recorded gap audio is pulled from the device
    And the gap audio is delivered before any live audio so the conversation stays in order
    And the device is told to advance past what was synced so nothing is pulled twice

  Scenario: a short gap joins the same conversation
    Given a conversation was interrupted by a short Bluetooth gap
    When the Omi reconnects and the gap audio arrives
    Then the same conversation continues under its original capture id

  Scenario: rapid listening restarts keep one buffered conversation
    Given my Omi has opened a conversation and its first audio is still buffered
    When the app restarts listening several times while I keep speaking
    Then I still have one conversation
    And all recorded audio belongs to the original conversation

  Scenario: relaunch before the first saved segment keeps the conversation
    Given my Omi has opened a conversation and its first audio is still buffered
    When the app relaunches within the conversation silence boundary
    Then the same conversation continues under its original capture id

  Scenario: a long gap starts a new conversation
    Given the Omi was away longer than the conversation silence boundary
    When the Omi reconnects
    Then a new conversation begins for the recovered and live audio

  Scenario: an Omi without a readable storage cache still streams live
    Given my Omi's storage cache is absent or speaks an older protocol
    When the Omi reconnects
    Then offline sync is skipped and live audio flows immediately

  Scenario: a stalled offline sync never blocks live audio
    Given an offline cache sync has started
    When the transfer stalls
    Then the sync is abandoned and held live audio is released in order
