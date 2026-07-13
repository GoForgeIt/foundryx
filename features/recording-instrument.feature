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
