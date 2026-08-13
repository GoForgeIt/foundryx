Feature: A client meets the real relay, and the contract is counted rather than assumed
  Every scenario below runs against a RELAY PROCESS THIS HARNESS STARTED. There is
  no injected responder anywhere in this target and there is no XCTSkip anywhere in
  it: a machine that cannot start a relay fails, because a green produced without a
  relay is the one result this track exists to refuse.

  The five elements of the published P3 client contract are not asserted from the
  relay's source. Each is DRIVEN over a real socket and its verdict is computed from
  what came back. That distinction is the whole point: an element marked served
  because a constant exists in the relay's source is an element nobody has met.

  Background:
    Given a relay process started from the binary the deployment's configuration key names
    And the harness has recorded that process's pid and the digest of the image it is running

  Scenario: the conforming client is admitted
    When a client asks for an address the deployment binds, naming the community it is bound to
    Then the connection is upgraded
    And the relay returns a session token

  Scenario: a client that names no community is refused and never upgraded
    When a client asks for an address the deployment binds, naming no community at all
    Then the connection is refused
    And the connection is never upgraded

  Scenario: a client that names a community the address is not bound to is refused and never upgraded
    When a client asks for an address the deployment binds, naming a community it is not bound to
    Then the connection is refused
    And the connection is never upgraded

  Scenario: every refusal writes the same bytes, and the number of causes exercised is reported
    When the client provokes a refusal by each distinct cause it can reach from outside
    Then every refusal is byte-identical
    And the number of distinct causes exercised is reported

  Scenario: the five contract elements are each driven, and the count is computed
    When the client drives each of the five published contract elements against the relay
    Then five contract elements are examined
    And the elements the relay serves are exactly the elements the register declares served
    And each element's individual questions are answered exactly as the register declares them
    And every element the relay does not serve is named with what the client observed

  Scenario: this target reports no green it did not run
    Then the target's own sources contain zero skip sites

  # LAST, and last on purpose. Tearing down mid-feature leaves every scenario after it
  # asking a dead process whether it is alive; the first run of this feature failed
  # exactly that way, and re-starting the relay from the Background to paper over it
  # would have let any scenario silently get a fresh relay.
  Scenario: the harness leaves nothing behind
    When the harness tears the relay down by the pid it captured
    Then no process the harness started is still listening
    And no scratch directory the harness created is left behind
    And the number of candidates examined for each is reported
