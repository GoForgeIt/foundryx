Feature: The read-aloud shows me where I am in the passage

  Teaching FoundryX my voice means reading a short passage aloud. A bare progress bar
  tells me how many seconds are left but not whether I am being HEARD — so the passage
  itself is the progress indicator: as I speak, each word I say lights up and stays lit.
  Words lock in permanently (the highlight never walks backwards while I am mid-sentence),
  a word I slur or skip does not stall the rest of the passage, and if on-device
  transcription is unavailable the read-aloud still works exactly as before — enrolling
  my voice must never depend on speech recognition being available.

  Scenario: words light up as I read them
    Given the voice step is showing the read-aloud passage
    When I speak the opening words of the passage
    Then those words are marked as spoken
    And the words I have not reached yet are still pending

  Scenario: spoken words stay lit
    Given the voice step is showing the read-aloud passage
    When I speak the opening words of the passage
    And the recogniser revises its guess about what it heard
    Then the words I already said are still marked as spoken

  Scenario: a skipped word does not stall my progress
    Given the voice step is showing the read-aloud passage
    When I read the passage but slur one word in the middle
    Then the words after the slurred one are still marked as spoken
    And my progress reflects almost the whole passage

  Scenario: progress is reported as a fraction of the passage
    Given the voice step is showing the read-aloud passage
    When I have read about half of the passage aloud
    Then my progress through the passage is about half

  Scenario: reading the whole passage completes it
    Given the voice step is showing the read-aloud passage
    When I read the entire passage aloud
    Then the passage is marked complete
    And every word is marked as spoken

  Scenario: unrelated speech does not light up the passage
    Given the voice step is showing the read-aloud passage
    When I say something that is not in the passage
    Then no words are marked as spoken

  Scenario: enrolment still works when transcription is unavailable
    Given the voice step is showing the read-aloud passage
    And on-device transcription is unavailable
    When I read the entire passage aloud
    Then no words are marked as spoken
    And I can still finish and store my voice sample
