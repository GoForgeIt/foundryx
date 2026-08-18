Feature: A recording comes over even though the transfer takes longer than one deadline
  A Pocket transfer is not one event. It is one announcement and then hundreds of audio
  notifications spread over as long as the file is long — measured at 21-36 KB/s on the owner's
  own recorder, which makes his largest recording tens of minutes on the wire. Every wait in the
  flow is bounded, and it has to be; what it may not be is bounded by a clock that started
  running during somebody else's wait.

  The timings in these scenarios are not invented. They are replayed from
  `Tests/FoundryXBrineTests/fixtures/pocket/pocket-fw16-ble-download-trace.json`, captured on
  2026-08-18 from PKT01_BLUE_26079bc5 on firmware 1.6.

  Scenario: A transfer longer than the control deadline still arrives whole
    Given a recorder replaying the captured transfer, whose longest silence is far inside the deadline
    When the recording is brought over
    Then every announced byte arrives and the recording is kept

  Scenario: A recorder that goes quiet mid-transfer is reported as a timeout, not as a shortfall
    Given a recorder that announces a size and then stops sending partway through
    When the recording is brought over
    Then the transfer fails as a download timeout rather than as an unreadable recording

  Scenario: The terminator frame the firmware sends does not poison the next command
    Given a recorder that sends its end-of-transfer frame after the last audio chunk
    When two recordings are brought over on one session
    Then both arrive whole and neither command reads the terminator as its answer
