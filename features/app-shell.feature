Feature: The app shell is three content tabs with Settings (incl. Devices) as a sheet
  One bottom tab bar, exactly three CONTENT tabs — Capture, Activity, Chat — with
  Capture as the launch tab. Device management is NOT a tab: it lives inside Settings
  as a "Devices & connections" page (Nick 2026-07-14), so there is one management home,
  not a competing tab. Settings opens as a sheet (gear in Capture/Activity), X to close.

  Scenario: the app shows Capture, Activity, Chat tabs in order
    When the app shell is presented
    Then the bottom tab bar shows exactly "Capture", "Activity", "Chat" in that order
    And the Capture tab is selected

  Scenario: neither Settings nor Device is a tab
    When the app shell is presented
    Then no tab is labelled "Settings"
    And no tab is labelled "Device"

  Scenario: Device management lives inside Settings
    When I open Settings
    Then I see a "Devices & connections" entry that opens the device page

  Scenario: Settings opens as a dismissable sheet with an X close
    When I tap the Settings gear
    Then Settings presents as a sheet
    And I can close it with an X
