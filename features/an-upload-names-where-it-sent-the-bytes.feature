Feature: an upload names where it sent the bytes, including nowhere

  Nine segments of a real voice note were ACK'd by Nick's phone at
  2026-08-17T12:00:53Z and could not be traced to any destination on any
  instrument. The relay diag named the handset, the WAL wrote "segment N ACK'd by
  desktop (saved to computer)", the durable upload watermark advanced past all
  nine so they will never be re-sent — and no door on earth had them. His phone
  was on the phone-only brain, which installs an upload closure that succeeds by
  doing nothing. The ACKs were self-issued.

  A destination that acknowledges and cannot be named is a custody hole, and the
  whole delete contract stands on it: a recording may leave the recorder only once
  somewhere else demonstrably holds it. "Somewhere else" has to be a place with a
  name.

  So every drain pass says where it is about to send audio, once, before it sends
  any; and every ACK repeats the same name. A phone that kept the bytes says it
  kept them. An upload handler that never named itself is reported as untraceable
  rather than being allowed to borrow the address of a door it never posted to —
  the target a WAL holds answers "where would this go", not "where did this go",
  and on the phone-only tier that address is a loopback port nothing listens on.

  Scenario: a drain to a door that is really listening names that door
    Given a capture pointed at a door that is really listening
    When the capture drains
    Then the drain names its destination exactly once
    And the drain's destination line names that door's capture address
    And the ACK line names that door's capture address
    And that door really received the bytes

  Scenario: on the phone-only brain the drain says the bytes never left
    Given a capture on the phone-only brain, whose upload keeps the bytes here
    When the capture drains
    Then the drain names its destination exactly once
    And the drain's destination line says the bytes stayed on this phone
    And no logged line claims the bytes reached a computer
    And no logged line names the door address the capture was pointed at

  Scenario: on the phone-only brain the ACK names this phone, not a door
    Given a capture on the phone-only brain, whose upload keeps the bytes here
    When the capture drains
    Then the ACK line says the bytes stayed on this phone
    And no logged line claims the bytes reached a computer

  Scenario: an upload handler that names nothing is reported as untraceable
    Given a capture whose upload is a handler that names nothing
    When the capture drains
    Then the drain names its destination exactly once
    And the drain's destination line says the ACK cannot be traced
    And no logged line names the door address the capture was pointed at

  Scenario: the phone-only brain is wired to name itself in production
    Given the brain seam as the app actually ships it
    Then a phone-only capture manager routes its uploads to this phone
    And a capture manager with a real brain routes its uploads to the door
