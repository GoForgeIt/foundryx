Feature: A listening conversation survives switching apps
  As someone relying on FoundryX to keep listening,
  I want the current conversation to remain usable when I leave and return,
  so changing apps never silently replaces or empties my recording.

  Scenario: the listening surface remains usable after returning to the app
    Given an ambient conversation is listening and has accumulated elapsed time
    When I switch to another app and return to FoundryX
    Then the same conversation is still listening
    And its elapsed time has not reset and continues advancing
    And I can pause the conversation from the listening surface
    When I open the listening conversation
    Then I see the active recording page

  Scenario: the live transcript survives returning to the app
    Given an ambient conversation is listening with live transcript words
    When I switch to another app and return to FoundryX
    Then the same conversation's live transcript still shows the captured words
    And the live transcript continues growing with new speech
