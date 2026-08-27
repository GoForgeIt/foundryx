Feature: the phone asks the computer across the seam

  Every other feature in this suite describes what a PERSON sees, or what a
  COMPONENT computes from a reading it was handed. None of them describe what
  crosses the wire between the phone and the computer.

  That gap is not theoretical. On 2026-08-26 the conversations route reached the
  Mac ZERO times over several hours while the phone was demonstrably connected,
  and the only artifact that showed it was the door's own arrival log. The phone
  kept no record of what it had sent, so the two ends of one seam could not be
  compared, and 1,802 green tests said nothing about it.

  These scenarios assert on the crossing itself.

  Scenario: asking the computer for its list actually crosses the seam
    Given a phone whose computer is reachable
    When the phone asks the computer for its list
    Then a request for the conversation list crosses the seam

  Scenario: the request rides the relay when a relay is what connects the two
    Given a phone whose computer is reachable
    When the phone asks the computer for its list
    Then that request crosses on the relay leg

  Scenario: without a relay the same request still crosses, directly
    Given a phone whose computer is reachable only on this network
    When the phone asks the computer for its list
    Then that request crosses on the direct leg

  Scenario: a phone that never asks leaves no crossing, and that is observable
    Given a phone whose computer is reachable
    Then no request for the conversation list has crossed the seam

  Scenario: the seam record carries no query, only the route
    Given a phone whose computer is reachable
    When the phone asks the computer for its list
    Then the recorded crossing carries no query string
