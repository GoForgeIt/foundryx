Feature: Bringing one recording over from a record-then-sync recorder

  A Pocket records on its own for days and hands finished MP3 files over on request. Everything
  needed to ask for one has been written for weeks — `PocketBLEClient.download`, the durable
  import commit point, the cadence ladder, the newest-first backlog order — and none of it had a
  caller, so no file has ever moved. These scenarios are that caller.

  WHY THIS IS A BRING-OVER AND NOT A RECORDING. The file already exists on the recorder before
  the phone is involved. Nothing here streams, so nothing here may reach the live capture
  machinery: no FrameRouter, no capture WAL, no Live Activity, no recording pill, no
  currently-recording state. `features/pocket-durable-sync.feature` states that invariant and
  this path is held to it by the same spy.

  WHAT IS STILL NOT PROVEN, AND IS NOT PRETENDED HERE. No Pocket has ever been asked for a file
  by anything, because the one unit anybody has driven was empty
  (foundryx-hearth proposal 20260806T0658 §7: "one real end-to-end pull is still pending"). The
  radio in these scenarios is a fake that answers the way the protocol client expects. That
  makes the leg real and the FIRMWARE's half unproven, which is exactly the state these
  scenarios claim and no more.

  Scenario: Bringing over the one recording on a recorder puts it in Solleva's custody
    Given a remembered recorder holding one short recording
    When I bring that recording over
    Then the recorder is asked for that file on the session the handshake opened
    And the file is kept where it can be read back byte for byte
    And that recording is listed as being in Solleva rather than only on the recorder

  Scenario: The smallest recording is offered first
    Given a remembered recorder holding a long recording and a short one
    When I bring the offered recording over
    Then the shorter file is the one that was asked for

  Scenario: A transfer that stops partway keeps nothing and says so
    Given a remembered recorder whose file stops arriving partway through
    When I bring that recording over
    Then Solleva keeps no partial copy and says the transfer did not finish
    And that recording is still listed as only on the recorder

  Scenario: A file that is not the audio this build understands is refused
    Given a remembered recorder whose file is not a readable recording
    When I bring that recording over
    Then Solleva keeps no copy and says it could not read the recording

  Scenario: Bringing the same recording over twice keeps one copy
    Given a remembered recorder holding one short recording
    When I bring that recording over twice
    Then one copy is kept and the recorder was asked only once

  Scenario: Bringing a file over never deletes it from the recorder
    Given a remembered recorder holding one short recording
    When I bring that recording over
    Then the recorder was sent no delete command and the deletion promise is still shown

  Scenario: A bring-over is not a recording
    Given a remembered recorder holding one short recording
    When I bring that recording over
    Then no FrameRouter, WAL, Live Activity, recording pill, or currently-recording state is reached
