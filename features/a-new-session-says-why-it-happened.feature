Feature: A new session says why it happened

  The queue opens a fresh conversation with the recorder for five different reasons: somebody
  stopped a recording, the recorder went quiet, the recorder left, a recording ran out of
  attempts, or the system handed the link back after killing the app. Until now the record showed
  the same thing for all five — a new session, with no cause.

  That cost this project eight app restarts in July, chasing a radio fault that was not there.
  Every re-attach was a consequence of something else, and nothing in the record said so.

  Scenario: Every reason a session restarts says something different
    Given all the reasons a session can restart
    Then no two of them read the same
    And none of them is unnamed

  Scenario: A stop reads as a stop, not as a fault
    Given the owner stopped a recording
    Then the record says the owner ended it
    And it is marked as a consequence of something the app or owner did

  Scenario: A recorder that goes quiet reads as the recorder's doing
    Given the recorder went quiet on the second of four attempts
    Then the record says the recorder went quiet
    And it says which attempt that was
    And it is not marked as something the app or owner did

  Scenario: A refused key reads as a refusal rather than a disconnect
    Given the recorder refused this phone's key
    Then the record says the recorder declined the key
    And it does not read as the recorder simply leaving
