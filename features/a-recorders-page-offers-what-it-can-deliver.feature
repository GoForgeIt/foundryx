Feature: Solleva's recorder page offers only what it can actually deliver

  This file replaces `a-recorders-page-offers-fast-sync.feature`, which proved the recorder page
  offered to bring a recording over the recorder's own network. It did, and the offer could not
  be honoured: the address a Pocket serves files from was never measured, and on 2026-08-20 six
  joins from a phone and a Mac established that the recorder's access point drops a client about
  eight seconds after the handshake completes — measured at 7.8s, 8.03s, 8.1s, 8.1s and 8.28s,
  including one run that issued the file-selection and begin-transfer commands over Bluetooth
  while the phone was still attached. Nothing that dies in eight seconds can carry a recording
  that runs twenty minutes.

  An offer a person can tap and never have honoured is worse than no offer. So the control is
  gone, and Bluetooth carries every recording. That it still does is proved by
  `a-recorders-page-offers-to-bring-a-recording-over.feature`, which is not duplicated here.

  WHY THESE SCENARIOS ARE WRITTEN OVER A POPULATION RATHER THAN AS AN ABSENCE. "The fast-sync
  button is gone" is satisfied by a page with no controls at all, by a rename, and by a `VStack`
  somebody emptied — the same objection `PocketRecorderDeleteGate` raises against asserting that
  a delete verb cannot exist. Both scenarios below therefore name what the page DOES offer and
  are paired with a check that the offer is non-empty, so neither can pass by deletion.

  Scenario: The page does not offer to sync over the recorder's own network
    Given the controls the recorder page offers for what a recorder is holding
    Then there is at least one control to offer
    And none of them offers to sync over the recorder's own network

  Scenario: Every control the page names is one a person can reach
    Given the controls the recorder page offers for what a recorder is holding
    Then there is at least one control to offer
    And the page draws every one of them
