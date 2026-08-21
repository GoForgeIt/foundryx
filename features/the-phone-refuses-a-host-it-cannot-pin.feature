Feature: The phone refuses a host it cannot pin
  The pin is the only thing between the phone and a door that registered itself under
  somebody else's tunnel. The gateway's answer used to be trusted to carry one: a
  missing machine id was coerced to the empty string, the empty string decoded to no
  key, and the phone dialled with no pin at all and completed the channel. The control
  was written in a comment ("open registration is safe with this pin") while the code
  made the pin optional, and an optional control is not a control.

  So the pin is now mandatory. A host designation the phone cannot turn into a door
  key is a REFUSAL — the phone gets no relay configuration, and there is therefore no
  connect to fail open. This is the client half of P1; the relay half is the door
  bearer and P3's auth middle.

  Background:
    Given a gateway answering the phone's host lookup

  Scenario: a host designation carrying a real door key resolves and is pinned
    Given the gateway names a host whose machine id is "a real door key"
    When the phone resolves its host
    Then the phone gets a relay configuration
    And the configuration pins exactly the door key the gateway named
    And the pin is 32 bytes
    And the interactive channel carries the same pin

  Scenario Outline: a host designation the phone cannot turn into a door key is refused
    Given the gateway names a host whose machine id is "<machine id>"
    When the phone resolves its host
    Then the phone refuses the host
    And the phone gets no relay configuration
    And the gateway was actually asked

    Examples: every way a machine id fails to be a door key
      | machine id               |
      | absent                   |
      | the empty string         |
      | not hexadecimal          |
      | 62 hex characters        |
      | 63 hex characters        |
      | 65 hex characters        |
      | a JSON number            |
      | JSON null                |
      | uppercase hex            |

  Scenario: the refusal says the host could not be pinned
    Given the gateway names a host whose machine id is "absent"
    When the phone resolves its host
    Then the phone refuses the host
    And the refusal tells the person their host could not be verified
    And the refusal is not the no-host-designated refusal

  Scenario: a relay configuration has no way to spell "no pin"
    Given the gateway names a host whose machine id is "a real door key"
    When the phone resolves its host
    Then the relay configuration's door key is not an optional
