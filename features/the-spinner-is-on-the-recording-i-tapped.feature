Feature: The spinner is on the recording I tapped

  Nick, watching his own recorder page: "if I could click on an individual recording and click
  bring over, it should show me the loading screen right there rather than taking me back to
  the home screen, and then if I do go back to the home screen, well, it is loading, it should
  show the loading spinner on the specific recording that I clicked to bring over not just at
  the top."

  The page could not do it. It had one in-flight flag per KIND of errand — checking, bringing
  over, removing — and not one of them carried a subject, so nothing in the app could answer
  "which of these nineteen recordings is moving?". The only honest place for a spinner was the
  top of the page, and the page about one recording had to close itself and send the owner back
  there to see it.

  These scenarios run inside the shipping app and drive the recorder page's own model. The only
  thing here that is not shipped code is the radio, which a hermetic run cannot own.

  Scenario: The recording I asked for is the one that says it is working
    Given a remembered recorder holding two recordings
    And that recorder has become slow to answer
    When I ask for the second recording by name
    Then that recording says it is being brought over
    And the other recording does not say it is being brought over
    And the other recording says why it cannot be asked for right now

  Scenario: Nothing is left spinning once the errand is over
    Given a remembered recorder holding two recordings
    And that recorder has become slow to answer
    When I ask for the second recording by name
    And I leave the recorder's page
    Then no recording says it is being brought over

  Scenario: Reading the shelf is about the recorder, not about any one recording
    Given a remembered recorder holding two recordings
    And that recorder has become slow to answer
    When I ask what that recorder is holding
    Then no recording says it is being brought over
    And the page says it is checking the recorder

  Scenario: The record says which recording the errand was about
    Given a remembered recorder holding two recordings
    And that recorder has become slow to answer
    When I ask for the second recording by name
    Then the record names that recording as what the errand is about
