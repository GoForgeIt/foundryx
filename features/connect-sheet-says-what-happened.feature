Feature: The connect sheet is legible — a short list, and a failure that says which step failed

  Two defects reported from a Pocket on a real phone.

  ONE: the "Connect a device" sheet listed every advertising peripheral in the room, and the
  ones broadcasting no name — which is most of them — all rendered as the same
  "Unnamed recording device" row. Reported as: "there's too many unnamed Bluetooth devices…
  they're just busy and kind of get in the way." They cannot simply be deleted: the sheet's own
  copy says FoundryX cannot tell what a device is until it connects to it, and a real recorder
  may broadcast no name at all. So they are FOLDED, never dropped, and only when there is
  something named to fold them behind.

  TWO: a Pocket lying against the back of the phone was tapped and answered
  "FoundryX couldn't connect to that device. Bring it closer and try again." Proximity ruled
  out the sentence's own explanation, and the sentence was the only thing the attempt produced.
  `RecordingDeviceAttachOutcome.unreachable` has always CARRIED the reason — a radio that was
  off, a peripheral this iPhone could not find, a connect that timed out, a service discovery
  that stalled, a link that dropped — and the presentation threw it away, so eleven distinct
  failures rendered one sentence, and that sentence named the one cause that had been ruled out
  by the device touching the phone.

  Driven against the shipped `RecordingDeviceScanFilter`, the shipped
  `RecordingDeviceAttachment` over the same BLE seam `CoreBluetoothCentral` wraps, and the
  copy `App/DeviceScreen.swift` renders 1:1.

  Scenario: devices that broadcast no name are folded away, not dropped
    Given a scan that has turned up two devices with names and five with none
    When the connect sheet's list is drawn
    Then only the two named devices are listed
    And the sheet says how many devices with no name it is holding back
    And asking to show them lists all seven, so none of them is unreachable
    And the connect sheet actually applies that filter to what it draws

  Scenario: when nothing broadcasts a name, the unnamed devices are the list
    Given a scan that has turned up three devices and not one of them broadcasts a name
    When the connect sheet's list is drawn
    Then all three are listed
    And the sheet holds nothing back

  Scenario: a tap that never reached the device says which step failed
    Given a discovered recorder this iPhone can no longer find
    When I tap that discovered device
    Then the app says it could not find that device rather than that it could not connect
    And the reason the attempt failed is carried in the outcome rather than discarded

  Scenario: connecting and then stalling is not the same sentence as never connecting
    Given a recorder that connects and then never says what it can do
    When I tap that discovered device
    Then the app says it connected and the device never described itself
    And that sentence is different from the one a device it never reached produces

  Scenario: every distinct way a tap can fail earns its own sentence
    Given the shipped connect-failure copy
    Then every reason a tap can fail to reach a device has a sentence of its own
    And no two of those sentences are the same
    And not one of them tells me to bring a device closer
    And every one of those sentences is in the population the brand-free gate is held over

  Scenario: a device this iPhone has lost track of is looked for again instead of failing
    Given a recorder this iPhone cannot look up but which is still advertising
    When I tap that discovered device
    Then the app finds it with a scan and adopts it anyway

  Scenario: the radio a tap opened is released when the tap is over
    Given a signed-in account and a discovered recorder FoundryX already holds the key for
    When I tap that discovered device
    Then the attempt is holding no central manager afterwards

  # THE ORDERING A REAL POCKET DEPENDS ON, asserted rather than assumed.
  #
  # `APP&SK&<key>` is answered over a NOTIFICATION (pocket-libre PROTOCOL.md:
  # characteristic 001120A3, Write+Notify). CoreBluetooth confirms a subscription
  # asynchronously, so a command written before that confirmation has nowhere to be
  # answered — the recorder never replies and the app waits on a link that is plainly
  # up. Build 779594 did exactly this against Nick's recorder: the attach reached
  # providingKey, wrote the key, and nothing ever came back.
  Scenario: no command is written to a recorder before it has confirmed it will answer
    Given a recorder that has not yet confirmed it will send replies
    When I tap that discovered device
    Then no command was written before that confirmation arrived

  Scenario: a recorder that never confirms it will answer is not blamed on the link
    Given a recorder that never confirms it will send replies
    When I tap that discovered device
    Then the sheet says it connected but stopped responding
    And that sentence does not claim the recorder could not be reached
