Feature: One recording-device experience, and copy that tells the truth

  Track 20260725T2306_device_agnostic_recording_source, task T5. There is ONE recording-device
  connection affordance leading to ONE list of everything discovery found, in an order derived
  from the device's own reported name and never from its family, with no control that removes
  a row because of its shape. A device that cannot supply usable audio is listed WITH an
  actionable, brand-free reason rather than hidden. A capability the device did not declare is
  reported as unavailable — never as a plausible default, and specifically never as a firmware
  version a user might quote to support.

  A conversation is attributed on the timeline to the device that RECORDED it, read from the
  device record beside it; a conversation from before device records shipped keeps its
  shipped attribution and is never called missing. Attribution follows the SELECTED ACTIVE
  device, chosen from the account-scoped store among the devices the transport says are
  ready — so a substitution changes what NEW audio is attributed to and changes nothing
  about what is already archived.

  WHAT IS DRAWN TODAY, AND WHAT IS ONLY DEFINED. The App target draws the recorder's name
  beside its own recordings (the conversation row's meta line and the detail header capsule)
  and the device metrics strip. The one device list, its capability lines and the gap sentence
  are DEFINED and asserted here and no view calls them yet — that surface is T6's, and
  `RecordingSurfaceRenderingLedgerTests` is the ledger that says which half a value is in and
  reds when either half moves. This feature therefore says "offered" and "reports" where the
  claim is about the defined experience, and "attributes" / "shows" only where a view draws it.

  Driven against the real `RecordingSourceCatalog`, the real `RecordingDeviceStore` and
  `RecordingDeviceActivation` in a sandboxed account container, the real `CaptureManager`
  writing real capture directories, the real `DeviceManager` producing gap outcomes, and the
  same presentation values the App target renders.

  Scenario Outline: each device shape connects through the one experience
    Given the app is signed in and has no recording device
    And an eligible "<shape>" device named "<name>" is discoverable
    And eligible devices of the other shapes are discoverable
    Then exactly one recording-device connection affordance is offered
    When I open that affordance
    Then all devices are offered together without a vendor or family choice
    And no list control that hides a device by family is offered
    When I connect "<name>" and record a conversation
    Then the production capture path finalizes the conversation
    And the timeline attributes it to "<name>"
    And generic device copy names no vendor
    Examples:
      | shape                 | name           |
      | Bluetooth audio route | Field Recorder |
      | Non-Omi BLE stream    | Trail Mic      |
      | Omi-shaped BLE stream | Omi            |

  Scenario Outline: unusable audio is refused without corrupting capture
    Given a discoverable external Bluetooth device has "<history>"
    When it supplies unusable audio "<phase>"
    Then the device is refused with an actionable reason
    And no unusable audio is persisted
    And any previously valid audio finalizes normally
    And other eligible devices remain available to connect
    Examples:
      | phase                | history               |
      | at connection        | delivered no audio    |
      | after capture begins | delivered valid audio |

  Scenario: absent capabilities are not invented
    Given a connected device declares no firmware value and no gap recovery
    Then the device experience reports both capabilities as unavailable
    And it shows no fabricated firmware value
    When the device disconnects and audio from the gap cannot be recovered
    Then the gap sentence for that outcome says the audio was not recoverable
    When the device disconnects still holding the audio it recorded
    Then the gap sentence for that outcome does not say the audio was not recoverable

  Scenario: another device substitutes without vendor priority
    Given two differently shaped devices are remembered across relaunch and both are ready
    And device A is the shape the shipped source ordering ranks last and device B is the shape it ranks first
    And device A is active because I selected it
    Then device A stays active while both devices are ready
    When device A becomes unready
    Then at most one device remains active
    And any hand-off follows preference and readiness rather than vendor identity
    When I select device B and record
    Then new audio is attributed to device B
    And archived audio remains attributed to device A

  Scenario: legacy pairing and history survive an account-scoped upgrade
    Given a legacy Omi pairing and legacy recordings exist before upgrade
    When the signed-in account launches the upgraded app
    Then the device remains paired and active without a physical re-pair
    And the legacy history keeps its attribution without onboarding
    When a second account signs in on the same handset
    Then it cannot see or activate the first account's device

  Scenario: device-agnostic history does not trigger onboarding
    Given an account's history contains only recordings made after device-agnostic source support
    When that account launches the upgraded app
    Then its recording history keeps its attribution
    And device onboarding does not run

  Scenario: a gap outcome is rendered into the account whose audio it is about
    Given a gap-recovery outcome was produced while one account was exposed
    When the exposed account has changed by the time it arrives
    Then the outcome is withheld with a reason rather than rendered
    When the outcome arrives while its own account is still exposed
    Then the outcome is rendered

  Scenario: the outcome a recording device delivers names the account its window opened under
    Given a recording device that has been told which account it is recording for
    And a conversation is interrupted and its gap window opens
    When the account this handset records for changes before the window closes
    And the gap window closes
    Then the delivered outcome names the account the window opened under
    And that outcome is withheld from the account now on screen

  Scenario: the account a gap outcome answers for follows the signed-in account
    Given a recording device that keeps track of which account it is recording for
    And that account signs out and a different account signs in
    And a conversation is interrupted and its gap window opens
    When the gap window closes
    Then the delivered outcome names the account that is signed in now

  Scenario: a gap window opened after sign-out no longer answers for the account that left
    Given a recording device that keeps track of which account it is recording for
    And that account signs out
    And a conversation is interrupted and its gap window opens
    When the gap window closes
    Then the delivered outcome does not name the account that signed out
    And that outcome is withheld from the account that signed out

  Scenario: a recording device never told an account delivers an outcome that names none
    Given a recording device that was never told which account it is recording for
    And a conversation is interrupted and its gap window opens
    When the gap window closes
    Then the delivered outcome names no account
    And that outcome is withheld with a reason rather than rendered into the account on screen
