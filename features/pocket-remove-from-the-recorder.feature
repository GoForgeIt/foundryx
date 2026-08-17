Feature: Taking a recording off the recorder, on purpose

  A recorder is the only place some recordings exist. So the rule is not "never remove anything"
  and it is not "remove whatever is safe to remove" — it is that nothing leaves the recorder
  unless Solleva can prove it already holds it somewhere else, and a person either chose that
  recording or armed that recorder themselves.

  There are two ways in and there is no third. A person taps one recording, or a person turns on
  automatic clearing for one recorder. Both read the SAME answer to "is this safe" — the one the
  recorder page already draws — because two answers to that question is how a recording gets lost.

  A recorder can also say no. Asked to remove a recording it does not have, this firmware answers
  with a refusal rather than a shrug, and a refusal is reported as a refusal. Nothing here trusts
  the acknowledgement: after asking, Solleva reads the recorder's own shelf again on the same
  trip, and only a recording that is actually gone is reported as gone.

  Scenario: A recording Solleva cannot prove it holds elsewhere is not taken off the recorder
    Given a recorder holding a recording that Solleva has not confirmed anywhere else
    When I ask Solleva to take it off the recorder
    Then Solleva refuses and says it has not confirmed a copy anywhere else
    And the recorder is never asked to remove anything

  Scenario: A recording Solleva has never checked on is not taken off the recorder either
    Given a recorder holding a recording Solleva has never checked on
    When I ask Solleva to take it off the recorder
    Then Solleva refuses and says it has not confirmed a copy anywhere else
    And the recorder is never asked to remove anything

  Scenario: A recording Solleva holds safely elsewhere is gone from the recorder's own shelf
    Given a recorder holding a recording Solleva has confirmed safe somewhere else
    When I ask Solleva to take it off the recorder
    Then Solleva asked that recorder to remove that one recording and no other
    And the recorder's own shelf no longer lists it
    And Solleva says it was removed from the recorder

  Scenario: A recorder that refuses is reported as having refused
    Given a recorder that will not remove the recording it is asked about
    When I ask Solleva to take it off the recorder
    Then Solleva says the recorder would not remove it
    And Solleva does not claim the recording is gone

  Scenario: A recording still on the shelf afterwards is never reported as removed
    Given a recorder that says yes to anything and removes nothing
    When I ask Solleva to take it off the recorder
    Then Solleva says the recording is still on the recorder
    And Solleva does not claim the recording is gone

  Scenario: A recorder listing what it holds is never mistaken for a removal
    Given the answers a recorder gives while it is listing what it holds
    Then not one of them reads as a recording having been removed
    And a recorder's refusal reads as a refusal, not as a removal
    And a recorder's yes still reads as a yes, so the reading is not blind

  Scenario: A recording is named back to the recorder exactly the way the recorder named it
    Given a recorder that names some of its recordings one way and the rest another way
    When I ask Solleva to take one of each off the recorder
    Then each request carried the recorder's own spelling of that recording, unchanged

  Scenario: Clearing a recorder automatically is off until I turn it on, and only for that recorder
    Given two recorders I have set up
    Then neither of them clears anything on its own
    When I turn on automatic clearing for the first recorder
    Then the first recorder clears a recording once it has synced
    And the second recorder still clears nothing on its own

  Scenario: Turning on automatic clearing does not reach back for what already synced
    Given a recorder whose recordings synced before I turned automatic clearing on
    When I turn on automatic clearing for that recorder
    Then nothing that synced before I turned it on is cleared
    And the next recording to sync after that is cleared

  Scenario: Automatic clearing meets the same bar a tap does
    Given a recorder with automatic clearing turned on
    Then a recording Solleva cannot prove it holds elsewhere is still not cleared
    And a recording Solleva has never checked on is still not cleared

  Scenario: What a person reads before anything is taken off a recorder
    Given the sentences a person reads about taking recordings off a recorder
    Then turning on automatic clearing says what synced is trusted to mean and where the copy went
    And on a phone with nowhere else to put a copy, automatic clearing is not offered at all
    And none of them promises an amount of space nobody has measured
    And the promise is still that Solleva never deletes anything you did not ask it to

  Scenario: The affordance exists only for a recording Solleva can prove it holds elsewhere
    Given a shelf with one recording confirmed safe elsewhere and one that is not
    Then only the confirmed recording offers to be taken off the recorder
    And a recording Solleva has never checked on offers nothing

  Scenario: I am told what this does, and where the copy already is, before it happens
    Given a recording Solleva has confirmed safe somewhere else
    When I choose to take it off the recorder
    Then I am asked to confirm first
    And what I am asked names the recorder and says where the copy already is
    And nothing is asked of the recorder until I confirm

  Scenario: A tap that cannot be carried out says so rather than doing nothing
    Given a recorder whose shelf Solleva could not re-read
    When I ask Solleva to take a recording off it
    Then Solleva says it cannot act on that recording right now
    And the recorder is never asked to remove anything

  Scenario: How full the recorder is, is re-read after something is taken off it
    Given a recorder holding a recording Solleva has confirmed safe somewhere else
    When I ask Solleva to take it off the recorder
    Then Solleva asked that recorder how full it is on the same trip
    And a recorder that refused to remove anything is not asked how full it is
