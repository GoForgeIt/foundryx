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

  # The hierarchy. Nick, looking at his own recorder page: "there is lots of scrolling to get
  # to any of the important controls or information". His recorder holds nineteen recordings,
  # and every control that acts on them — bring one over, sync them fast, start the recorder
  # over, arm the automatic clear — was drawn UNDERNEATH all nineteen rows. A control below an
  # unbounded list is a control that exists at a length nobody can predict, which for a full
  # recorder is the same as not existing. The list is the only band on this page that has no
  # ceiling, so the list goes last and everything a person can act on is met before it.
  Scenario: Every control on the recorder page is met before the list of recordings
    Given the bands the recorder page is laid out in
    Then the list of recordings is the last band
    And every control is met before that list
    And there are controls to meet, and a list to meet them before
    And the page draws its bands in the order that was decided, and draws every one of them

  # The repetition, in a row. From the same screenshots: one row said "Only on the recorder"
  # and then "On the recorder: Yes - just now" and then "On this iPhone: No - just now" and
  # then "Safe elsewhere: No - just now". Four lines, three facts, and the first line is only
  # the other three said again in prose. None of the three places may be dropped — they are
  # what makes deleting a recording safe — so the summary is what goes, and the three places
  # are compressed onto one line with the age they share stated once.
  Scenario: One shelf row states where a recording is exactly once
    Given every way one recording can be placed
    Then each row names each of the three places exactly once
    And no row states the same fact twice
    And the age they share is stated once, not once per place
    And the page renders that one statement about where a recording is, and no second one

  # The repetition, one band apart, and this one was photographed. The page's own simulator
  # proof showed "58%" and "1.6" as readings and then "Battery 58%" and "Firmware 1.6" again in
  # the capability strip directly underneath — one number, twice, within one screen height. The
  # page had carried a comment saying battery and firmware had left that strip; nothing had
  # carried it out. A capability strip states what a device CAN do; a reading states what it
  # SAID. When the same key is both, the reading wins, because it is the one that carries a
  # number and the moment it was read.
  Scenario: A recorder does not state its charge twice, one band apart
    Given a connected recorder that declared its charge and its firmware and answered them
    Then the readings state its charge and its firmware
    And the capability strip states neither of them again
    And the strip still states what only it knows
    And a device with no readings band keeps its charge in the strip

  # The repetition, one band higher. A recorder nobody has checked drew "Connect and check
  # now" three times — once under Battery, once under Free space, once under Firmware — and a
  # recorder that answered drew "just now" three times for one moment.
  Scenario: The readings strip states an age once and offers one way to ask
    Given a recorder that answered every reading at one moment
    Then the strip states that moment once
    And a recorder nobody has asked is offered one way to ask, not one for every fact
    And the strip still names every fact it has, asked or not
    And the page renders the strip that was compressed rather than a line for every reading
