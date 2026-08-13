Feature: Solleva's recorder page brings a recording over

  `features/pocket-bring-over.feature` proves the TRANSFER — ask the recorder for a file, keep
  it only if it reads back whole, say what happened. Every one of those scenarios passes
  against an object the test itself built, and every one would go on passing if no screen in
  Solleva had a way to start one. That is not a worry about the future: `PocketBLEClient
  .download` and `RecordingDeviceAdoption.remember` each shipped complete, each covered by
  scenarios, and each with no caller anywhere in the application.

  These scenarios are about the APPLICATION. They run inside the shipping app's own process on
  a simulator and drive the recorder page's own model — the code in `App/`, which no other
  suite in this repository is able to execute at all. The only thing that is not shipped code
  is the radio, which a hermetic run cannot own.

  Scenario: Asking a recorder what it is holding offers its recording
    Given a remembered recorder holding one recording
    When Solleva asks that recorder what it is holding
    Then Solleva says what is on the recorder
    And Solleva offers to bring that recording over

  Scenario: A recorder holding nothing offers nothing to bring over
    Given a remembered recorder holding nothing
    When Solleva asks that recorder what it is holding
    Then Solleva says what is on the recorder
    And Solleva offers nothing to bring over

  Scenario: Bringing the offered recording over puts it in Solleva's custody
    Given a remembered recorder holding one recording
    When Solleva asks that recorder what it is holding
    And I bring the offered recording over
    Then Solleva says it kept the recording
    And the recorder's shelf now says that recording is in Solleva
