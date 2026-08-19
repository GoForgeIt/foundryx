Feature: audio reaches the place that resolved, or stays pending until it can

  Fifty-four Omi captures — 22,358 segments, 6 hours 12 minutes, ~103 MB — exist
  nowhere. The cell 404s every one of them while `pkt-` ids from the same phone,
  the same account and the same window return 1660 and 710 contiguous seqs, so the
  404 means ABSENT, not unreachable. `lore.db` holds none of the 54.

  Two faults produced that, and either one alone would have been survivable.

  The first is a gate with no rung between "my computer" and "nothing left the
  phone". A chosen computer brain whose host stops resolving falls all the way to
  the phone-only tier even when a vault IS paired and reachable — the vault is
  only ever routed to when it was the explicitly chosen brain. So every ambient
  recording made while the Mac was off-LAN self-ACK'd, while recordings brought
  over in the app reached the vault.

  The second is what made that unrecoverable rather than merely delayed. The
  phone-only tier's "upload" is a closure that succeeds by doing nothing, and the
  WAL wrote a durable `.ack` marker and advanced the upload watermark past bytes
  it had never sent. The watermark is the resume point: past it, nothing is ever
  re-sent. A backfill run a minute later could not find the segments, because the
  phone had already recorded them as done.

  So: a route that sent nothing may not write an ACK and may not move the
  watermark. It records a HOLD instead — the bytes are accounted for on this
  handset, which is all the local tier ever needed — and the moment a route that
  really posts is resolved, that hold is pending audio again and drains for real.

  Scenario: a paired vault is a destination, not a degrade to this phone
    Given a signed-in owner who chose their computer as the brain
    And that computer's host does not resolve
    And a vault that is paired
    When the app resolves where a recording goes
    Then the recording goes to the vault
    And the recording does not go to this phone only

  Scenario: with no vault paired there is still nowhere else to go
    Given a signed-in owner who chose their computer as the brain
    And that computer's host does not resolve
    And no vault that is paired
    When the app resolves where a recording goes
    Then the recording goes to this phone only

  Scenario: a self-issued ACK never advances the durable upload watermark
    Given a capture whose upload keeps the bytes on this phone
    When the capture drains
    Then the durable upload watermark has not moved
    And no segment carries an ACK marker

  Scenario: audio the phone kept is uploaded once a real destination resolves
    Given a capture whose upload keeps the bytes on this phone
    And the capture drains
    When a destination that is really listening resolves and the capture drains again
    Then that destination really received the bytes
    And the durable upload watermark has moved

  Scenario: connecting a vault re-arms every recording the phone kept
    Given a recording the phone kept and self-ACK'd before this fix shipped
    When the owner connects a vault
    Then that recording is re-armed for upload
