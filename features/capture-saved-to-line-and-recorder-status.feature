Feature: The capture page names the place a voice note actually went

  Nick's brain is Solleva Cloud. He owns no computer. His Capture tab said
  "All voice notes saved to computer".

  THE MECHANISM, MEASURED: the settled sync line was computed from a BOOLEAN
  ("is this the phone-only tier?") while the app has THREE brains — RootGate
  resolves to computerBrain, cellBrain or phoneBrain. The cell brain and the
  computer brain both handed that boolean `false`, byte-identically, so the
  cell brain inherited the computer's sentence. A three-valued state crushed
  into a boolean, and a unit test pinned the crushed value in place.

  So the destination is now named from the brain the app RESOLVED to, and it is
  asserted for all three — not for the two that happen to agree today.

  The same defect had a second site with no branch at all: the WAL logged every
  segment ACK as "ACK'd by desktop (saved to computer)" whatever the target was,
  and the upload itself logged no address. That is what made a reader conclude,
  from the phone's own log, that a cell-brain user was on a computer. A log line
  now names the place the bytes actually reached.

  The header is the second half. It led with one vendor's "Connect your Omi"
  pairing block on a page that is meant to be recorder-agnostic. Whatever is
  connected — or nothing — is now ONE status icon at the trailing edge of the
  saved-to line: green when something is connected, and a tap opens the devices
  page in Settings, where connections are actually managed.

  Scenario: on the computer brain the line names the computer
    Given the app resolved to the computer brain
    Then the settled sync line reads "All voice notes saved to computer"

  Scenario: on the cloud brain the line names the Vault, not a computer
    Given the app resolved to the cloud brain
    Then the settled sync line reads "All voice notes saved to your Vault"
    And the settled sync line does not mention a computer

  Scenario: on the phone-only brain the line claims no other place at all
    Given the app resolved to the phone brain
    Then the settled sync line reads "All voice notes saved"
    And the settled sync line does not mention a computer

  Scenario: every brain the gate can resolve to names its own destination
    Given every brain the root gate can resolve to
    Then each brain's saved-to line names that brain's own destination and no other
    And no two brains share a saved-to line

  Scenario: the empty capture page never invites a vendor pairing block that is gone
    Given every brain the root gate can resolve to
    Then no brain's empty-library invitation names a vendor
    And no brain's empty-library invitation points at a block above it

  Scenario: a connected recorder reads green
    Given a recorder is connected
    Then the recorder status icon is green
    And its label names no vendor

  Scenario: a recorder whose link is being re-established does not read green
    Given a recorder link is being re-established
    Then the recorder status icon is not green
    And its label names no vendor

  Scenario: a recorder that is off the air does not read green
    Given no recorder is connected
    Then the recorder status icon is not green
    And its label says nothing is connected

  Scenario: the phone's own microphone is not a connected recorder
    Given only the phone's built-in microphone is available
    Then the recorder status icon is not green

  Scenario: the status icon opens the devices page inside Settings
    Given the recorder status icon
    Then tapping it opens the "Devices & connections" page on the Settings tab

  Scenario: the capture header no longer leads with a vendor pairing block
    Given the capture screen as the app actually ships it
    Then the capture screen offers no "Connect your Omi" button
    And the capture screen renders the recorder status badge from the shared model
    And the capture screen takes its saved-to line from the resolved destination

  Scenario: a segment ACK names the place the bytes actually reached
    Given a capture whose door is a Vault at "https://vault.example.dev"
    When a segment is uploaded and acknowledged
    Then the ACK log line names "https://vault.example.dev/foundryx/capture"
    And the ACK log line does not claim the bytes reached a computer

  Scenario: an upload through a relay names the tunnel it went down
    Given a capture whose door is reached through relay tunnel "tun-abc123"
    Then the logged upload destination names "tun-abc123"
    And the logged upload destination does not claim the bytes reached a computer
