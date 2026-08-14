Feature: Bringing one recording over from a record-then-sync recorder

  A Pocket records on its own for days and hands finished MP3 files over on request. Everything
  needed to ask for one had been written for weeks — `PocketBLEClient.download`, the durable
  import commit point, the cadence ladder, the newest-first backlog order — and none of it had a
  caller, so no file had ever moved. These scenarios are that caller, and they now follow the
  file all the way to being a conversation.

  WHY THIS IS A BRING-OVER AND NOT A RECORDING. The file already exists on the recorder before
  the phone is involved. Nothing here streams, so nothing here may start a live recording: no
  FrameRouter, no Live Activity, no recording pill, no currently-recording state, no capture the
  app thinks is arriving. It DOES write the ordinary durable segments a finished capture is made
  of, and then hands that capture to the ordinary drain and the ordinary finalize, because
  inventing a second way to get audio to the brain is the one thing this leg was told not to do.
  `CaptureManager.merge` has shipped exactly that shape — pre-existing segments on disk, then
  pending-finalize, then sync, then finalize — since long before any Pocket existed.

  WHAT THE FIXTURES ARE. Real MPEG-2 Layer III audio at the recorder's own 32 kbps CBR, not two
  bytes that satisfy a sync-word check. See `Tests/FoundryXBrineTests/fixtures/pocket`. A leg
  that decodes cannot be proven by a fixture that does not decode.

  WHAT IS STILL NOT PROVEN, AND IS NOT PRETENDED HERE. No physical Pocket has ever been asked
  for a file by anything (foundryx-hearth proposal 20260806T0658 §7: "one real end-to-end pull is
  still pending"). The radio in these scenarios is a fake that answers the way the protocol
  client expects. That makes the leg real and the FIRMWARE's half unproven, which is exactly the
  state these scenarios claim and no more.

  Scenario: Bringing over the one recording on a recorder puts it in Solleva's custody
    Given a remembered recorder holding one short recording
    When I bring that recording over
    Then the recorder is asked for that file on the session the handshake opened
    And the file is kept where it can be read back byte for byte
    And that recording is listed as being in Solleva rather than only on the recorder

  Scenario: A brought-over recording becomes an ordinary conversation
    Given a remembered recorder holding one short recording
    When I bring that recording over
    Then a conversation exists holding that recording's audio as ordinary capture segments
    And the conversation is dated to when the recorder says it was recorded
    And the conversation records which recorder it came from

  Scenario: A brought-over recording finalizes through the path every recording uses
    Given a remembered recorder holding one short recording
    When I bring that recording over and the app takes the conversation
    Then the same upload and finalize a phone recording uses carried it to the brain
    And no second ingest route was used

  Scenario: A long recording is never held in memory
    Given a remembered recorder holding a recording a minute long
    When I bring that recording over
    Then the audio was written out as it decoded, never assembled whole

  Scenario: A recorder that announces more than it listed is stopped
    Given a remembered recorder that lists a short file and then announces a huge one
    When I bring that recording over
    Then Solleva keeps no copy and says it could not read the recording

  Scenario: The smallest recording is offered first
    Given a remembered recorder holding a long recording and a short one
    When I bring the offered recording over
    Then the shorter file is the one that was asked for

  Scenario: A transfer that stops partway keeps nothing and says so
    Given a remembered recorder whose file stops arriving partway through
    When I bring that recording over
    Then Solleva keeps no partial copy and says the transfer did not finish
    And that recording is still listed as only on the recorder
    And no conversation was created

  Scenario: A file that is not the audio this build understands is refused
    Given a remembered recorder whose file is not a readable recording
    When I bring that recording over
    Then Solleva keeps no copy and says it could not read the recording
    And no conversation was created

  Scenario: Bringing the same recording over twice keeps one copy
    Given a remembered recorder holding one short recording
    When I bring that recording over twice
    Then one copy is kept and the recorder was asked only once
    And one conversation exists, not two

  Scenario: Bringing a file over never deletes it from the recorder
    Given a remembered recorder holding one short recording
    When I bring that recording over
    Then the recorder was sent no delete command and the deletion promise is still shown

  Scenario: A bring-over is not a live recording
    Given a remembered recorder holding one short recording
    When I bring that recording over
    Then no FrameRouter, Live Activity, recording pill, or currently-recording state is reached
    And the conversation was never streaming
