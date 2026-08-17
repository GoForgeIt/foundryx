Feature: Solleva's recorder page can bring a recording over the recorder's own network

  `features/pocket-fast-sync.feature` proves the HANDOFF — prove the recorder is ours, join the
  network it reports, fetch the file, keep it, put the recorder back on Bluetooth. Every one of
  those scenarios passed against an object the test itself built, and every one went on passing
  while `PocketFastSyncCoordinator` had ZERO constructors outside its own test file and the word
  "FastSync" appeared nowhere under `App/`. The repository's own reachability register said so in
  those words: `unreachable`, "constructed only in its own feature test".

  These scenarios are about the APPLICATION. They run inside the shipping app's own process on a
  simulator and drive the recorder page's own model — the code in `App/`, which no other suite in
  this repository can execute at all. The only things that are not shipped code are the radio and
  the WiFi, which a hermetic run cannot own.

  Scenario: The recorder page offers fast sync and says what it costs
    Given a remembered recorder holding one recording
    When Solleva asks that recorder what it is holding
    Then Solleva offers fast sync and says the phone leaves its normal network

  Scenario: Fast sync puts the recording in Solleva the same way Bluetooth does
    Given a remembered recorder holding one recording and a network this phone can join
    When Solleva asks that recorder what it is holding
    And I bring the offered recording over with fast sync
    Then Solleva says it kept the recording
    And the recorder's shelf now says that recording is in Solleva
    And the recorder was put back on Bluetooth

  Scenario: Fast sync that cannot fetch the file keeps nothing and says so
    Given a remembered recorder holding one recording and a network that serves no file
    When Solleva asks that recorder what it is holding
    And I bring the offered recording over with fast sync
    Then Solleva says nothing was kept
    And the recorder was put back on Bluetooth
