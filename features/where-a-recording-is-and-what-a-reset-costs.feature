Feature: Where a recording is, and what starting the recorder over would cost

  A recorder's shelf used to answer one question with two words: "In Solleva" or "Only on the
  recorder". Those two words cannot say "on this phone, but not yet safe anywhere else" — and
  that is precisely the state that decides whether it is safe to clear the recorder. Worse,
  they cannot say "nobody has checked": a place nobody asked about was drawn with the same
  confidence as a place that answered no.

  So a recording now has three places — the recorder, this iPhone, and somewhere safe that is
  neither — each with its own answer and its own age, and "we never checked" is a third answer
  rather than a quiet no.

  The safe-elsewhere answer is the one everything destructive reads. It is deliberately
  generous about WHERE: a recording whose local audio was cleared away months later is still
  safe, because the confirmation that it reached the person's own library outlives the audio.
  A predicate that read only the local audio would go false on the recordings that worked best,
  and would close the gate on exactly the people it was built for.

  Scenario: A recording whose local audio was cleared away is still safe
    Given a recording brought off a recorder, confirmed in the person's library, whose local audio has since been cleared away
    Then Solleva says that recording is safe elsewhere
    And a recording confirmed nowhere is not said to be safe

  Scenario: A place nobody asked about reads unknown, never no
    Given a recorder whose shelf Solleva has just read, and a phone it has not been asked about
    Then the row says the recording is on the recorder, and how long ago that was read
    And the row says it does not know whether the recording is on this iPhone
    And the row does not say the recording is safe elsewhere
    And the age of a place nobody asked about is shown as never checked

  Scenario: Starting the recorder over says what it would cost
    Given a recorder holding three recordings, one of which Solleva already has
    Then starting the recorder over is offered
    And it says two recordings are on the recorder and not on this iPhone

  Scenario: A stale look at the recorder changes what is asked first, not what is allowed
    Given a recorder holding three recordings, one of which Solleva already has
    When the last look at that recorder is an hour old
    Then starting the recorder over is still offered
    And the first thing it asks for is a fresh look at the recorder

  Scenario: Forgetting the recorder states the same cost in the same terms
    Given a recorder holding three recordings, one of which Solleva already has
    Then forgetting the recorder repeats what forgetting costs
    And it says two recordings are on the recorder and not on this iPhone

  Scenario: Keeping notes on this phone alone is never counted as safe elsewhere
    Given a person who keeps their notes on this phone alone
    When a recording is finished and transcribed on the phone
    Then Solleva does not say that recording is safe elsewhere
    And the sentence about where a copy goes is this phone's own, not the computer's
