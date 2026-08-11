Feature: One device list wires Pocket and Omi as peers

  Track 20260810T2158_unified_recording_device_list_wires_pocket_and_omi, building the screen
  DESIGN-pocket-connect.md §2 already specifies. Settings → Devices used to open on an Omi HERO
  BLOCK — a vendor name, a "Not paired" state and a Battery / Signal / Firmware strip reading
  `N/A · N/A · N/A` — above a separate CAPTURE SOURCES section, with no Pocket anywhere. A hero
  block IS "vendors first", which is what "one list" quietly becomes the moment class is a
  section rather than a caption.

  So: one list, four shapes, the same row grammar for all of them — a name and one line reading
  `<class> · <state>`. The order is the shipped `merge()` order, `displayName.lowercased()` then
  `storageKey`, with shape DELIBERATELY ABSENT from the comparison. Where a live device shows
  recording state, a record-then-sync device shows what is actually true instead: a fact about
  the link, never about recording.

  Driven against the real `RecordingSourceCatalog`, the real `RecordingDeviceStore` in a
  sandboxed account container, the real Pocket identity and discovery bridge, and the same
  presentation values `App/DeviceScreen.swift` renders.

  Scenario: one list, ordered by name and identity, with shape absent from the comparison
    Given an audio-route headset, this iPhone's microphone, a paired Omi and a paired Pocket
    When the device list is drawn
    Then the rows read in name order rather than in shape order
    And every row uses the same grammar of a name and a class and a state
    And grouping those same devices by shape would produce a different list

  Scenario: a paired Pocket is a peer row that says nothing about recording
    Given an audio-route headset, this iPhone's microphone, a paired Omi and a paired Pocket
    When the device list is drawn
    Then the Pocket row reads "Records on its own · Not connected"
    And the Pocket row is not first and not last by virtue of its shape
    When the Pocket is handed a claim that it is recording right now
    Then its row still reports only whether the link is reachable

  Scenario: an unpaired device renders no battery value at all
    Given a remembered device that has never reported a battery level
    When the device list is drawn
    Then that row carries no battery value
    And no row anywhere in the list says "N/A"
    And a device that did report its battery shows the value it reported

  Scenario: the Settings subtitle counts classes and names no vendor
    Given an audio-route headset, this iPhone's microphone, a paired Omi and a paired Pocket
    When the device list is drawn
    Then the Settings entry subtitle reads "3 live, 1 records on its own"
    And that subtitle contains no vendor name

  Scenario: a record-then-sync device page substitutes the truth for recording state
    Given a paired Pocket that is not connected
    When its device page is built
    Then the page carries the recorder-light sentence where a live device carries record and stop
    And the page offers no record or stop control
    And the page never says the device is in range
    And the page's capability strip is battery firmware gap recovery and offline storage
    And the page's capability strip has no signal column
    And its education comes from the protocol it speaks and not from its shape

  Scenario: a device page claims only the capabilities and custody it actually has
    Given this iPhone's microphone and a Bluetooth headset the account does not remember
    When each device page is built
    Then neither page renders a capability it can never fill
    And neither page offers to forget a device the account does not remember
    And a remembered live device is offered forget without a claim about a key

  Scenario: a record-then-sync device reaches no live surface in any state
    Given a paired Pocket that is not connected
    Then its class may not contribute a Live Activity in any state
    And a live device's class may
    When a stored-file device is discovered attached displayed disconnected and reconnected
    Then no active source FrameRouter WAL Live Activity or live state mutation occurs

  Scenario: the connect affordance and its copy are the shipped brand-free strings
    Given the shipped recording-device connect copy
    Then the affordance is titled "Connect a recording device"
    And the list is titled "Recording devices"
    And the scanning and empty lines name no vendor
    And the education line above the list explains the one distinction the list is organised by
    And that link opens the class explanation rather than one device's light
    And the app presents the recorder setup screen from the connect affordance
    And no branded setup row is pinned above whatever answered the scan

  Scenario: tapping a discovered recorder runs the app's own adoption chain end to end
    Given a signed-in account and a discovered recorder FoundryX already holds the key for
    When I tap that discovered device
    Then the transport client established which protocol that device speaks
    And FoundryX authenticated it and read its battery and firmware over the radio seam
    When the account's remembered devices are read back
    Then the redrawn list shows it as a peer row reading "Records on its own · Not connected"

  Scenario: a recorder FoundryX holds no key for stops at the setup screen and touches nothing
    Given a signed-in account and a discovered recorder FoundryX holds no key for
    When I tap that discovered device
    Then the app says setup isn't available yet instead of adding a row
    And FoundryX sent that recorder nothing at all
    And the account does not remember that recorder

  Scenario: the pairing scan is not restricted to one vendor's service
    Given the connect affordance has started a pairing scan
    Then the scan carries no service filter at all
    And a device advertising no live-audio service still answers it and appears in the list

  Scenario: the account's remembered Pocket survives a relaunch as a peer row
    Given a signed-in account that pairs a Pocket through the shipped adoption seam
    When the account's remembered devices are read back
    Then the Pocket is remembered under its stored-file identity
    And the redrawn list shows it as a peer row reading "Records on its own · Not connected"
