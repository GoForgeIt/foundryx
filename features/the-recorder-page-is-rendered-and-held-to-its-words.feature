Feature: The recorder page is shown in the build, and held to its words and its colours
  Nobody has ever seen the recorder page in a build. The pictures the build takes cover the
  recording surface, the actions list, the deletion choice and the device list — and not one
  of them is the page a person opens to look at what their recorder is holding. So "never
  ship a screen without seeing it" has been a habit somebody has to remember, on the one
  screen in this app whose states nobody can reach without a Bluetooth radio in the room.

  Two habits, not one. The second is quieter and it has already been broken: a sentence a
  person reads can be typed straight into the page, where no test can reach it, instead of
  living beside the sentences that are checked. The same is true of a colour. Both are
  invisible to every test this app has, because the tests cannot compile the page at all.

  A rule that only forbids is worthless here. "No sentence is written into the page" is
  perfectly true of a page that says nothing, and "no colour is mixed into the page" is
  perfectly true of a page that paints nothing — so each prohibition below is paired with
  the existence it would otherwise pass on.

  # The pictures. A state nobody can see is a state nobody reviewed.
  Scenario: Every state the recorder page can be in is shown in the build's pictures
    Given the states the recorder page can be in
    Then the build takes a picture of every one of them
    And the build is told to take those pictures on every run
    And there is at least one state to take a picture of

  # The words.
  Scenario: A sentence a person reads is never written into the recorder page itself
    Given the recorder page as it is written
    Then not one sentence a person reads is written into the page itself
    And the page still says things that were written where they can be checked

  # The colours.
  Scenario: A colour on the recorder page is never mixed on the page itself
    Given the recorder page as it is written
    Then not one colour is mixed on the page itself
    And the page still paints colours that come from the design system
