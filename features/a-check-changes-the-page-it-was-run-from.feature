Feature: A check changes the page it was run from

  "Connect and check now" opens a session with a recorder, reads its charge, its firmware and
  how full it is, and writes all three down against that recorder. The page the tap came from
  renders the value it was handed when the row was opened, and nothing re-reads what the check
  wrote — so the shelf fills with recordings while Battery, Free space and Firmware each go on
  offering the button that would go and measure numbers already sitting on this phone's disk.

  The header has the same defect from the other end. A recorder that records on its own has no
  live link to report: the check opens its own session and closes it again, so a status line
  taken from a link state reads "Not connected" while Solleva is actively listing that
  recorder's files. The only live state this class of device has is what a CHECK is doing.

  Scenario: The numbers a check measured reach the page the check was run from
    Given a remembered recorder nobody has ever checked, with its page open
    When Solleva checks that recorder from that page
    Then the battery, the free space and the firmware each show a number and how long ago it was read
    And no fact on that page still offers the action that would ask

  Scenario: A recorder's header never claims a link it cannot have
    Given a remembered recorder nobody has ever checked, with its page open
    Then the header says nobody has checked this recorder
    And the header states no link state

  Scenario: The header says a check is running while a check is running
    Given a remembered recorder nobody has ever checked, with its page open
    When a check against that recorder is in flight
    Then the header says a check is running
    And the header states no link state

  Scenario: The header says when the recorder answered
    Given a recorder that answered twenty minutes ago, with its page open
    Then the header says the recorder answered twenty minutes ago
    And the header states no link state
