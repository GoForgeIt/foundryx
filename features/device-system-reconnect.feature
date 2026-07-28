Feature: A system link drop reconnects and continues the same conversation, while a user detach stays detached

  Track 20260725T2306_device_agnostic_recording_source, task T4. The first scenario is the
  spec's S04 verbatim; the rest are the arms it depends on and the controls that stop its
  Thens from being satisfiable for the wrong reason.

  Driven through the injected CoreBluetooth seam against the REAL `DeviceManager` and the
  REAL `CaptureManager`: a scripted device answers `discoverServices` / `discoverCharacteristics`
  / `setNotifyValue` on the manager's own BLE queue and pushes real Opus frames up the audio
  characteristic. Nothing injects `.streaming` into `CaptureManager` and nothing calls
  `resumeSession` — the whole chain (link drop -> re-issued pending connect -> connect
  completes -> services -> audio characteristic -> `.streaming` -> resume) runs in production
  code, or the scenario fails.

  Scenario: system reconnect preserves continuity while user detach stays detached
    Given an active external recording device is capturing a conversation
    When the system link drops and returns inside the existing short-gap boundary
    Then the device reconnects without reopening the app
    And capture resumes the same conversation
    When I explicitly detach the device
    Then it remains detached until I reconnect it

  Scenario: the app is relaunched during the drop and the conversation still continues
    Given an active external recording device is capturing a conversation
    When the system link drops and the app is relaunched before the device returns
    And the device returns inside the silence gap
    Then capture resumes the same conversation
    And exactly one conversation exists on disk

  Scenario: a device the user switched off is not re-armed by a system link drop
    Given an active external recording device is capturing a conversation
    When I switch the device off
    And the system link drops
    Then no connection is re-issued
    And the same drop on an armed device does re-issue one

  Scenario: iOS relaunches the app for a restored connection and the conversation continues
    Given an active external recording device is capturing a conversation
    When iOS kills the app and relaunches it holding the still-connected device
    Then the restored connection is rediscovered without issuing a new connect
    And capture resumes the same conversation

  Scenario: a reconnect that never rediscovers the audio stream does not claim to have resumed
    Given an active external recording device is capturing a conversation
    When the system link drops and the device returns without its audio stream
    Then the device reconnects without reopening the app
    And capture is still waiting for the device rather than resumed
