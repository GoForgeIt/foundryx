Feature: A client meets the real relay, and the contract is counted rather than assumed
  Every scenario below runs against a RELAY PROCESS THIS HARNESS STARTED, and there is
  no XCTSkip anywhere in this target: a machine that cannot start a relay fails, because
  a green produced without a relay is the one result this track exists to refuse.

  CORRECTED 2026-08-13, AND THE CORRECTION IS ITSELF NOW A COUNT. This paragraph used to
  say "there is no injected responder anywhere in this target", and that sentence was
  FALSE. `Tests/FoundryXConformanceTests/DoorFixture.swift` constructs a `NoiseXXResponder`
  in this process and runs a real msg1/msg2/msg3 handshake — deliberately, because P1's
  subject is whether the CLIENT proceeds, and "proceeds" only means anything against a
  real counterpart.

  What is true is narrower, and it is what this target actually owes. For every P3
  contract-element drive the endpoint under test is the separately started `foundry-relay`
  binary whose pid and image digest this harness records, and no in-process peer is ever
  credited as evidence that THAT binary implements a handshake. P1 separately uses
  FoundryXKit's own responder as the door counterpart, behind a separately started blind
  tunnel relay — a different binary, for a different question. A universal nobody counted
  is how the false sentence survived, so the part of this that can be counted is counted
  below instead of asserted here.

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
    And every unserved element names which of its questions were answered no and which were never asked
    And every unasked question names what blocks it, and everything it names was answered no

  Scenario: this target reports no green it did not run
    Then the target's own sources contain zero skip sites

  # The count that replaces the false universal this feature used to open with. It is two
  # numbers, not one, because the true claim has two halves: this target's own sources hold
  # DIRECT handshake-peer constructor calls (one, P1's door) and the sources that drive the
  # five contract elements hold none. A single total would be satisfied by moving a peer
  # from one file into the element drive.
  #
  # It is a LEXICAL census of direct constructor call sites in this target's own directory,
  # and it is named that way rather than "the peers this target uses" because those are not
  # the same set: the P1 drive reaches a peer INDIRECTLY through the production client, and
  # no census of this directory can see that. What it can see is the thing worth guarding —
  # a peer appearing next to the element drive, or the declared number moving on its own.
  Scenario: the direct handshake-peer constructor sites in this target are counted, and none is in the element drive
    Then the number of direct handshake-peer constructor sites in this target is the number it declares
    And the sources that drive the five contract elements contain none of them
    And the files examined for both counts are reported, with what the census cannot see

  # LAST, and last on purpose. Tearing down mid-feature leaves every scenario after it
  # asking a dead process whether it is alive; the first run of this feature failed
  # exactly that way, and re-starting the relay from the Background to paper over it
  # would have let any scenario silently get a fresh relay.
  Scenario: the harness leaves nothing behind
    When the harness tears the relay down by the pid it captured
    Then no process the harness started is still listening
    And no scratch directory the harness created is left behind
    And the number of candidates examined for each is reported
