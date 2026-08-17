Feature: A recording that came off a recorder plays here, and its row says where it is

  Every other recording in Solleva was made by this phone and then sent to the computer, so
  "Listen" has always meant "ask the computer for it". A recording that came off a pocket
  recorder is the first audio this app has ever KEPT on the phone: the original file the
  recorder handed over is still sitting here, whole, because it is the one thing that makes a
  failed import free to retry.

  So asking the computer for it would be absurd — it would put a person's own recording behind a
  computer that might be asleep, on a plane, or in another country. It plays from this phone,
  and the computer is never asked.

  Being on the phone is not the same as being safe. A recording lives in three places — the
  recorder, this iPhone, and somewhere safe that is neither — and the row says all three at once,
  each with its own age, with a place nobody asked about reading unknown rather than no.

  Solleva keeps the recorder's original file on this iPhone and cannot yet free that space. That
  is said out loud on the row rather than left for somebody to discover as missing.

  Scenario: A recording that came off a recorder plays with the computer unreachable
    Given a recording brought off a recorder, whose original file is on this iPhone
    And the computer that holds the other recordings can't be reached
    When I tap Listen on that recording
    Then the recording plays
    And Solleva never asked the computer for it

  Scenario: A recording this phone made is still asked of the computer
    Given a conversation this phone recorded with its own microphone
    When I tap Listen on that recording
    Then Solleva asks the computer for it

  Scenario: A recording that came off a recorder but is not on this phone is asked of the computer
    Given a recording that came off a recorder, whose original file this phone is not holding
    When I tap Listen on that recording
    Then Solleva asks the computer for it

  Scenario: The row says all three places at once
    Given a recording brought off a recorder, whose original file is on this iPhone, confirmed in the person's library
    Then the row says the recording is on this iPhone
    And the row says the recording is safe elsewhere
    And the row does not claim to know whether the recording is still on the recorder
    And the age of a place nobody asked about is shown as never checked

  Scenario: A recording held on this phone is never blamed on the computer
    Given a recording brought off a recorder, whose original file is on this iPhone but cannot be played
    When I tap Listen on that recording
    Then Solleva says it could not play the recording that is on this iPhone
    And it does not say the computer can't be reached

  Scenario: Freeing the space this phone's copy takes is named as something Solleva does not do yet
    Given a recording brought off a recorder, whose original file is on this iPhone
    Then the row says Solleva keeps the original here and cannot free that space yet

  Scenario: Deleting the account takes the recordings off this phone with it
    Given a recording brought off a recorder, whose original file is on this iPhone
    When the account's data is deleted
    Then no recording brought off a recorder is left on this iPhone
