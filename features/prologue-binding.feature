Feature: a handshake is bound to the tenancy it was made for, by bytes neither side sends

  The design binds a P3 channel's handshake to `(normalized_host || negotiated_version)` so that
  "a handshake transcript completed for community A's host cannot be replayed against community B,
  because the prologue disagrees". Those bytes are NEVER PUT ON THE WIRE — each side mixes them
  into its own transcript hash before the first message — so a peer cannot be asked what it bound
  and cannot be caught out by reading the wire. The only way to observe the binding at all is to
  run a handshake and watch it complete or fail.

  WHY THIS FILE EXISTS. The conformance target's `prologue-bytes` element is NOT SERVED, and its
  third question — a transcript completed for one address must not complete against another — is
  recorded NOT REACHED, because the relay sends nothing after the upgrade for a transcript to
  exist in. For four measurements that question had no drive at all, so "not reached" and "nobody
  knows how to ask it" were the same sentence. These scenarios separate them: the question gets an
  ORACLE here, executed and graded by mutations that make it fail, and what remains missing at the
  relay is a SUBJECT.

  WHAT THIS DOES NOT CLAIM. Nothing here talks to a relay and nothing here says a relay has this
  property. `Package.swift` puts this target outside the conformance target's dependency closure
  precisely so that an obligation met here cannot be read as met against a real peer, and
  `scripts/check-conformance-topology.py` asserts that separation. The conformance element stays
  NOT SERVED and the count stays 4 of 5 whatever these scenarios say.

  Background:
    Given two peers that already hold everything they need to complete a handshake
    And every value both peers use is pinned except what each side binds the handshake to

  Scenario: peers that bind the handshake to the same tenancy complete it and can then talk
    Given both peers bind the handshake to the same address and the same agreed version
    When the two peers run the handshake
    Then the handshake completes
    And each side can read what the other encrypts

  Scenario: a peer that binds the handshake to a different address cannot complete it
    Given the two peers bind the handshake to different addresses
    When the two peers run the handshake
    Then the handshake fails
    And neither side is given transport keys

  Scenario: a peer that binds the handshake to a different agreed version cannot complete it
    Given the two peers bind the handshake to the same address but to different agreed versions
    When the two peers run the handshake
    Then the handshake fails
    And neither side is given transport keys

  Scenario: one byte of disagreement is enough, and that byte is the only difference
    Given the two peers bind the handshake to addresses that differ in exactly one byte
    When the two peers run the handshake
    Then the handshake fails
    And a second run that changes nothing but that one byte completes

  # The last two scenarios are about a DIFFERENT question: not whether the binding works, but
  # whether the conformance target is knocking on the door in a way anybody could answer. Its
  # second question — does a handshake happen after the upgrade at all — was driven by putting
  # the tenancy bytes on the wire and waiting. Nothing in the design says a peer answers those.
  # Both verdicts are the same against today's relay, which closes the socket either way; they
  # differ entirely against a relay that grows the handshake, which is the only case that
  # question exists for.

  Scenario: the tenancy bytes on their own are not something a peer can answer
    Given a peer that speaks the handshake correctly and is waiting to be spoken to
    When it is handed the tenancy bytes on their own
    Then it cannot read them as an opening at all

  Scenario: an opening message is something a peer answers
    Given a peer that speaks the handshake correctly and is waiting to be spoken to
    When it is handed an opening message of the size the handshake defines
    Then it answers with a message of its own
