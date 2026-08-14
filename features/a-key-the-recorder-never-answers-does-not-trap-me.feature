Feature: A key the recorder never answers does not trap me

  THE REPORTED DEFECT, AND IT IS A DEADLOCK RATHER THAN A MESSAGE.

  Tapping a recorder in "Connect a device" produced "That device stopped answering while
  FoundryX was unlocking it. Tap it again." — forever. The recorder was proven healthy from a
  Mac in the same room: `APP&SK&<its key>` answers `MCU&SK&OK`, `APP&LIST_DIRS` lists five
  days, and `APP&U&…` hands over a whole MP3. Solleva was holding a DIFFERENT key, and this
  firmware answers a wrong key with SILENCE rather than with a refusal.

  Silence becomes `PocketOnboardingState.indeterminate`, which becomes
  `RecordingDeviceUnreachableReason.handshakeUnanswered`, which was an inline caption and
  nothing else. The key stayed in custody, so every retry restored the same unusable key and
  asked the same silent question. The one screen that can replace a key —
  "I already have this recorder's key" — hung off `.setupUnavailable`, which by definition
  means "Solleva holds NO key", so a recorder Solleva holds a bad key for could never reach it.
  `features/pocket-existing-key-entry.feature` already specifies this exit for a key the
  recorder REFUSES. There was no equivalent for a key it never answers.

  WHAT THESE SCENARIOS ARE. They run inside the shipping app's own process on a simulator and
  drive `RecordingDeviceAttachModel` — the tap handler in `App/DeviceScreen.swift`. A scenario
  against a hand-built object graph would pass whether or not the application can reach the
  screen, and reachability is the entire defect. The only thing here that is not shipped code
  is the radio, which a hermetic run cannot own.

  Scenario: A recorder that never answers the key Solleva holds lands on a screen with a way out
    Given a recorder that answers only the key it was set up with, and Solleva holds a different key
    When I tap that recorder in the connect sheet
    Then Solleva puts up a screen rather than a caption I can only retry
    And it says the recorder did not answer the key Solleva is holding
    And it does not claim that key is the wrong one
    And that screen offers to let me enter a key
    And it offers to try the recorder again

  Scenario: The key Solleva could not get an answer for is still in custody
    Given a recorder that answers only the key it was set up with, and Solleva holds a different key
    When I tap that recorder in the connect sheet
    Then the key Solleva holds is still in secure custody
    And Solleva sent that recorder exactly one key

  Scenario: I reach the key field from that screen and my recorder joins the list
    Given a recorder that answers only the key it was set up with, and Solleva holds a different key
    When I tap that recorder in the connect sheet
    And I choose to enter a key I already have
    Then Solleva is showing me the key field
    When I enter the key that recorder was actually set up with
    Then the recorder is adopted through the shipped chain
    And the key Solleva now holds is the one the recorder answered

  Scenario: Retrying without a new key is honest rather than a loop that says nothing
    Given a recorder that answers only the key it was set up with, and Solleva holds a different key
    When I tap that recorder in the connect sheet
    And I ask Solleva to try that recorder again
    Then Solleva is still on the screen that offers to let me enter a key
    And it says the recorder did not answer the key Solleva is holding
    And Solleva sent that recorder one key per attempt and no more

  Scenario: The screen never shows me the key Solleva is holding
    Given a recorder that answers only the key it was set up with, and Solleva holds a different key
    When I tap that recorder in the connect sheet
    Then no setup screen offers to reveal, copy, share, or export a key
    And the key Solleva holds appears in no line the setup screens can display
