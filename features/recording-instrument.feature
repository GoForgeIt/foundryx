Feature: The recording instrument

  The same ring the user met at welcome and voice enrollment is the live
  recording instrument: its motion follows the voice in the room, it settles
  when paused, and it never pretends a conversation is "complete". A long
  recording earns a provisional name partway through, from what has actually
  been said. Recording never chains the user to one tab: leaving the capture
  page keeps recording, a quiet pill offers the way back, and the conversation
  can be ended right from the pill.

  Scenario: the ring follows the conversation
    Given I am recording
    When someone speaks
    Then the ring moves with the voice
    When I pause the recording
    Then the ring goes nearly still

  Scenario: a recording earns its name from what was said
    Given I am recording and nothing has been said yet
    Then the recording shows no provisional title
    When enough has been said
    Then a provisional title appears from the spoken words
    And it updates in place rather than jumping the layout

  Scenario: recording survives leaving the tab
    Given I am recording on the capture page
    When I switch to the chat tab
    Then the recording continues
    And a recording pill shows the elapsed time
    When I tap the pill
    Then I am back on the capture page

  Scenario: I can end the conversation from the pill
    Given I am recording and away from the capture page
    When I end the recording from the pill
    Then the conversation finalizes normally

  # The recording hero tile IS the live tile (track 20260717T0600). While recording,
  # the hero slot itself becomes a full-size live tile — the big ring, the elapsed time
  # from the session's start, the live words — and the whole tile opens the recorder.
  # The old cramped compact strip is gone.

  Scenario: the record hero becomes the live recording tile
    Given I am recording on the capture page
    Then the record hero shows the live recording tile
    And the live tile shows the recording ring at hero size
    And the live tile shows the elapsed time from the session start
    And the live tile shows the live words being spoken
    When I tap the live tile
    Then the full recording screen opens

  Scenario: not recording shows the record call to action
    Given I am not recording and no source is connected
    Then the record hero shows the "Record a conversation" call to action
    And the live recording tile is not shown

  Scenario: the cramped compact strip is gone
    Given I am recording on the capture page
    Then the record hero shows the live recording tile
    And the compact recording strip never appears

  Scenario: a paused recording still reads as the live tile
    Given I am recording on the capture page
    When I pause the recording
    Then the live tile still shows, marked paused
    And the elapsed time is still shown

  Scenario: a connected source with no conversation yet still gets the live slot
    Given a source is connected with no active conversation
    Then the record hero shows the live recording tile
    And the live tile shows no elapsed time
    And the live tile is not tappable to open the recorder
