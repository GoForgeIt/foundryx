Feature: Recording devices are remembered per account, and detaches stick

  Track 20260725T2306_device_agnostic_recording_source, task T2. Pairing state is
  account-scoped: a second account on the same handset cannot see or activate the first
  account's devices. A device paired before this track survives the upgrade without a
  physical re-pair, and one paired while signed out is RETAINED without being assigned to
  an arbitrary account until its owner signs in. An explicit detach persists; nothing
  automatic may undo it. Device status leaving the handset carries an account-scoped
  opaque reference or nothing at all.

  Driven against the real CaptureAccountScope resolution with a sandboxed container — the
  scope, the roots, and the files are the production ones.

  Scenario: signed-out upgrade does not leak or discard legacy pairing
    Given a legacy device is paired and no account is signed in during upgrade
    Then the device is retained without assignment to an account
    When its owner signs in
    Then the device is restored without a physical re-pair

  Scenario: a second account cannot see or activate the first account's devices
    Given account "first" is signed in and has remembered a device named "Trail Mic"
    When account "second" signs in on the same handset
    Then the second account remembers no devices
    And the second account cannot make "Trail Mic" active
    When account "first" signs back in
    Then it still remembers "Trail Mic"

  Scenario: a signed-out hold is adopted once and never handed to a second account
    Given a legacy device is paired and no account is signed in during upgrade
    When its owner signs in
    Then the device is restored without a physical re-pair
    When account "second" signs in on the same handset
    Then the second account remembers no devices
    When a crash leaves the signed-out hold's records in place
    And account "third" signs in and tries to adopt the hold
    Then the hold reports that it was already consumed
    And the second account remembers no devices

  Scenario: adopting the legacy pairing twice changes nothing
    Given account "first" is signed in
    And a legacy device pairing is present in the shipped device-global defaults
    When the legacy pairing is adopted
    Then the account remembers exactly one device
    When the legacy pairing is adopted again
    Then the account remembers exactly one device
    And the shipped device-global pairing is still present

  Scenario: an explicit detach survives relaunch and no automatic path undoes it
    Given account "first" is signed in and has remembered a device named "Trail Mic"
    And the device is ready
    Then it is the active device
    When I detach "Trail Mic" myself
    Then no device is active
    When the app relaunches and the device is ready again
    Then no device is active
    When I reconnect "Trail Mic" myself
    Then it is the active device

  Scenario: forgetting a device on the device page and pairing it again makes it active once more
    Given account "first" is signed in
    And the transport remembers a paired device "Trail Mic"
    And the device is ready
    Then it is the active device
    When I forget the device on the device page
    Then the detach is recorded against my account
    And no device is active
    When the app relaunches and the device is ready again
    Then no device is active
    When I pair the same device again on the device page
    Then it is the active device

  Scenario: the active device follows preference and readiness, never vendor identity
    Given account "first" is signed in
    And two remembered devices "Alpha Recorder" and "Omi" are both ready
    And I have chosen "Alpha Recorder"
    Then it is the active device
    And swapping which device is the BLE one does not change the active device
    When "Alpha Recorder" stops being ready
    Then "Omi" is the active device
    When I have chosen "Omi" instead
    Then "Omi" is the active device
    And at most one device is active

  Scenario: device status is withheld when there is no account secret
    Given no account secret is available
    When device status is prepared for the handoff
    Then no outbound device reference is produced
    And the withheld reason is recorded as "no_account_key"
    And the same preparation does produce a reference once an account secret exists

  Scenario: two accounts holding the same physical device cannot be correlated
    Given the same physical device is remembered by two different accounts
    When device status is prepared for each account
    Then the two outbound references differ
    And each account's reference is stable across relaunch
    And neither reference contains the display name or the raw hardware identifier
