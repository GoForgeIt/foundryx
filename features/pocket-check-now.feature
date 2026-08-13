Feature: Checking a remembered recorder reads what is actually on it

  A record-then-sync recorder hands its audio over after the fact, so until the bring-over path
  runs end to end the one honest thing this app can offer for one is to open a session and read
  back what the recorder is holding. Nothing is downloaded and nothing is deleted.

  THE LEG THIS EXERCISES THAT NOTHING ELSE DID. Every previous stored-file scenario closed the
  protocol session the moment custody was settled — `adoptStoredFileRecorder` called
  `client.close()` on every branch and `attach` then tore the link down — so `listDates` and
  `listRecordings` had no caller anywhere outside the protocol client's own unit tests. A
  session that outlives its own handshake is what these scenarios are about, and the proof is
  that the inventory commands appear on the SAME session as the one key handshake.

  Driven against the same wrapped BLE seam `DeviceManager` runs on, so the code under test is
  the shipped `RecordingDeviceAttachment`, `PocketSeamTransport`, `PocketBLEClient`,
  `PocketOnboardingCoordinator` and `PocketRecordingDeviceBridge`. Only the radio is injected.

  Scenario: Checking a remembered recorder lists what it is holding
    Given a remembered recorder FoundryX holds the key for, holding two recordings
    When I check that recorder now
    Then the check reports the recorder's battery and firmware
    And it lists both recordings newest first with a duration for each
    And every listed recording says it is only on the recorder
    And the panel offers one bring-over action and repeats the deletion promise

  Scenario: The inventory is read on the session the handshake opened
    Given a remembered recorder FoundryX holds the key for, holding two recordings
    When I check that recorder now
    Then one key handshake was issued and the listing commands followed it on that same session
    And the recorder was sent no download, no delete and no WiFi command
    And the link was closed once the answer was in hand

  Scenario: A recorder FoundryX holds no key for is not listed and is sent nothing
    Given a remembered recorder FoundryX holds no key for
    When I check that recorder now
    Then the check says the key is missing rather than showing an empty shelf
    And no listing command was issued

  Scenario: A recorder that cannot be reached is not reported as empty
    Given a remembered recorder that is not reachable
    When I check that recorder now
    Then the check says the recorder could not be reached rather than showing an empty shelf

  Scenario: A recorder holding nothing says so in words
    Given a remembered recorder FoundryX holds the key for, holding nothing
    When I check that recorder now
    Then the check reports an empty shelf in words and still repeats the deletion promise
    And the panel claims no recording state and no Live Activity

  Scenario: A recorder that answers the handshake and not the listing says which happened
    Given a remembered recorder FoundryX holds the key for that will not answer a listing
    When I check that recorder now
    Then the check says it connected but got no list rather than showing an empty shelf
