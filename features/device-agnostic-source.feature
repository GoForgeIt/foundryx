Feature: Any eligible external recording device is described by capability, not by vendor

  Track 20260725T2306_device_agnostic_recording_source, task T1. The catalog beneath the
  device list turns whatever discovery found — a Bluetooth audio-route input, a non-Omi BLE
  stream, an Omi-shaped BLE stream — into ONE list of entries, each carrying its own shape,
  stable identity, capability set, and adapter. Eligibility is decided by ONE rule applied
  to the declared audio format; vendor or model identity decides nothing. A device that
  cannot supply usable audio is refused with an actionable reason instead of having its
  bytes coerced into some other device's framing.

  Driven against the real `RecordingSourceCatalog` / `RecordingDeviceReconnectPolicy` with
  injected observations — no radio, no hardware.

  Scenario: every discoverable shape lands in one list with its own shape, identity, and adapter
    Given a Bluetooth audio-route device named "Field Recorder" is discoverable
    And a non-Omi BLE stream device named "Trail Mic" is discoverable
    And an Omi-shaped BLE stream device named "Omi" is discoverable
    When the source catalog merges what discovery found
    Then the list contains "Field Recorder", "Trail Mic" and "Omi"
    And every entry carries its own shape, a stable identity, and an adapter
    And no entry is ranked ahead of another because of its vendor name

  Scenario: the merged list does not depend on which device was discovered first
    Given a Bluetooth audio-route device named "Field Recorder" is discoverable
    And a non-Omi BLE stream device named "Trail Mic" is discoverable
    And an Omi-shaped BLE stream device named "Omi" is discoverable
    When the source catalog merges what discovery found
    And discovery reports the same devices in the opposite order
    Then the merged list is unchanged

  Scenario Outline: a device that cannot supply usable audio is refused with an actionable reason
    Given an eligible device of every shape is discoverable
    And a "<shape>" device named "Bad Mic" declares "<format>"
    When the source catalog merges what discovery found
    Then "Bad Mic" is refused with an actionable reason
    And the refusal text names no vendor
    And every other discovered device is still eligible to connect
    Examples:
      | shape                 | format                 |
      | Bluetooth audio route | no audio format at all |
      | BLE stream            | an unsupported codec   |
      | BLE stream            | a 4000 Hz sample rate  |

  Scenario: eligibility is judged by the audio format alone, never by the shape or the name
    Given a device declaring a usable audio format is discoverable under every shape
    When the source catalog merges what discovery found
    Then every one of them is eligible
    When the same usable format is re-declared under a different shape and a different name
    Then its eligibility is unchanged
    When the same unusable format is re-declared under a different shape and a different name
    Then its eligibility is unchanged

  Scenario: a capability the device does not report is unavailable, never a default
    Given a discoverable device declares no firmware value and no gap recovery
    When the source catalog merges what discovery found
    Then its firmware capability is unavailable
    And its gap-recovery capability is unavailable
    And no firmware value is fabricated

  Scenario: a capability this build does not understand neither crashes discovery nor creates a vendor branch
    Given a discoverable device declares a capability this build has never heard of
    When the source catalog merges what discovery found
    Then the device is still listed
    And that capability is not available
    And it is recorded as not understood rather than silently dropped

  Scenario: a system link drop re-arms the connection while a user detach stays detached
    Given an armed recording device of each shape
    When the system link drops
    Then the connection is re-issued without any user gesture
    And that decision is the same one the shipped BLE reconnect policy makes
    When I detach the device myself
    Then the device stays detached
    And no automatic path re-arms it
    When I reconnect it myself
    Then the connection is re-issued
