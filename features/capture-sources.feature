Feature: FoundryX capture-source registry with per-source toggles

  The device page lists capture sources, each independently toggleable on/off (not a
  mutually-exclusive single pick). The registry is extensible: Omi + phone mic are the
  built-in seeds; a Bluetooth microphone is discovered + added for real; an Apple Watch
  is a non-toggleable scaffold. Among the enabled + ready sources exactly ONE is active,
  chosen by priority (Omi > Apple Watch > Bluetooth mic > phone mic). Driven against the
  real CaptureSourceRegistry with an in-memory store + a fake input discovery — no UI,
  no hardware.

  The device page itself (track 20260714T1800 §8) renders from pure presentation
  values: the phone mic is offered as a second capture source, the Computer memory
  section offers pairing honestly on this screen (no Settings redirect), and the
  app-only scanner / splitting / add-source controls are gone.

  Scenario: the registry lists the built-in capture sources, both enabled by default
    Given a fresh capture-source registry
    Then it lists the "Omi wearable" and "Phone microphone" sources
    And both are enabled by default

  Scenario: toggling a source off persists across relaunch
    Given a fresh capture-source registry
    When I turn off the "Omi wearable" source
    Then the "Omi wearable" source is off
    When the app relaunches with the same saved settings
    Then the "Omi wearable" source is still off

  Scenario: enabling and disabling a source
    Given a fresh capture-source registry
    When I turn off the "Phone microphone" source
    Then the "Phone microphone" source is off
    When I turn on the "Phone microphone" source
    Then the "Phone microphone" source is on

  Scenario: discovering and adding a Bluetooth microphone
    Given a fresh capture-source registry
    And a Bluetooth microphone "AirPods Pro" is connected
    When I discover Bluetooth microphones
    Then the add-source list offers "AirPods Pro"
    When I add the "AirPods Pro" Bluetooth microphone
    Then the registry lists a source named "AirPods Pro" with its own toggle

  Scenario: the active source is the highest-priority enabled connected source
    Given a fresh capture-source registry
    And the Omi is connected
    Then the active capture source is the Omi
    When I turn off the "Omi wearable" source
    Then the active capture source is the phone microphone

  Scenario: the Apple Watch source is a non-toggleable scaffold
    Given a fresh capture-source registry
    When I add the Apple Watch source
    Then the "Apple Watch" source is present but cannot be toggled
    And the Apple Watch is never the active source

  Scenario: phone mic is offered as a second source
    Given a fresh capture-source registry
    Then the device page describes the phone microphone as "Use this iPhone as another capture source"
    And the phone microphone row has its own toggle

  Scenario: the device page offers my computer connection honestly
    Given no computer is paired
    Then the computer memory section is titled "Connect your computer"
    And it explains "Pair the desktop app for full-history search and local Brain runs"
    And its status reads "Not connected"
    And a primary "Connect your computer" button offers pairing right there
    And the pairing footer reads "Pairing is end-to-end encrypted to your own machine."
    When my computer "Nick's MacBook" pairs
    Then the computer memory section shows "Nick's MacBook"
    And it reads "Desktop app paired · Full-history search ready"
    And its status reads "Connected"
    And a "Disconnect computer" option replaces the connect button

  Scenario: the device page keeps only what the prototype shows
    Given the device page as shipped
    Then it has no Bluetooth battery scanner, no conversation splitting, and no add-source controls
    And the device metrics are Battery, Signal, and Firmware
