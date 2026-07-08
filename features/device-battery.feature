Feature: Battery indicator for connected audio devices

  When an external audio device that reports its battery (like the Omi) is connected,
  the app shows its battery level, so the user knows when to charge it. Devices that
  don't publish a battery level (e.g. AirPods, which iOS keeps private to the system)
  simply show no battery — never a wrong or fake value.

  Scenario: a connected Omi shows its battery level
    Given my Omi is connected and reports its battery level
    When I look at the device indicator
    Then I see the Omi's battery percentage

  Scenario: the battery updates as it changes
    Given my Omi is connected and showing a battery level
    When the Omi reports a new battery level
    Then the indicator updates to the new percentage

  Scenario: a low battery is shown as a warning
    Given my Omi is connected and its battery is below twenty percent
    When I look at the device indicator
    Then the battery indicator is styled as a warning

  Scenario: a device that does not report battery shows none
    Given a connected device that does not expose a battery service
    When I look at the device indicator
    Then no battery percentage is shown

  Scenario: find and monitor a Bluetooth device's battery
    Given a nearby Bluetooth device publishes its battery level
    When I choose to find Bluetooth devices
    And I select that Bluetooth device
    Then I see the Bluetooth device's battery percentage

  Scenario: the monitored device reconnects on relaunch
    Given I am monitoring a Bluetooth device's battery
    When I relaunch the app
    Then the app reconnects to that Bluetooth device
    And I see its battery percentage when it reports one

  Scenario: stop monitoring clears it
    Given I am monitoring a Bluetooth device's battery
    When I stop monitoring that Bluetooth device
    Then the app forgets that Bluetooth device
    And no Bluetooth device battery percentage is shown

  Scenario: a device without a battery service is not offered
    Given a nearby Bluetooth device does not publish its battery level
    When I choose to find Bluetooth devices
    Then that Bluetooth device is not offered for battery monitoring
