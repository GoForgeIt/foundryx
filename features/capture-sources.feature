Feature: FoundryX capture-source registry with per-source toggles

  The device page lists capture sources, each independently toggleable on/off (not a
  mutually-exclusive single pick). The registry is extensible: Omi + phone mic are the
  built-in seeds; a Bluetooth microphone is discovered + added for real; an Apple Watch
  is a non-toggleable scaffold. Among the enabled + ready sources exactly ONE is active,
  chosen by priority (Omi > Apple Watch > Bluetooth mic > phone mic). Driven against the
  real CaptureSourceRegistry with an in-memory store + a fake input discovery — no UI,
  no hardware.

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
