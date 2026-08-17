Feature: A recorder I armed actually clears itself

  Turning on automatic clearing is a promise: once Solleva has confirmed a copy somewhere other
  than this phone, that recording comes off the recorder without me asking again. A control that
  is safe, off by default, correctly scoped and never retroactive — and that never actually
  removes anything — has kept none of that promise. It has only avoided breaking it.

  So this is the scenario that watches a recording go all the way: armed, brought over, confirmed
  somewhere else, and then gone from the recorder's own shelf. And the control beside it, where
  the one thing that changes is that nothing was ever armed.

  Scenario: An armed recorder clears a recording once Solleva has confirmed it elsewhere
    Given a remembered recorder holding one recording, with automatic clearing armed
    When I bring that recording over
    And Solleva confirms it is safe on my computer
    And Solleva checks that recorder again
    Then Solleva asked that recorder to remove that recording
    And it is gone from the recorder's own shelf

  Scenario: A recorder nobody armed clears nothing, however safe the recording is
    Given a remembered recorder holding one recording, with automatic clearing left alone
    When I bring that recording over
    And Solleva confirms it is safe on my computer
    And Solleva checks that recorder again
    Then Solleva never asked that recorder to remove anything
    And the recording is still on the recorder's own shelf
