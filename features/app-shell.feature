Feature: The app shell is four tabs — Capture, Activity, Chat, Settings
  One bottom tab bar, exactly four tabs — Capture, Activity, Chat, Settings — with
  Capture as the launch tab. Settings is a first-class bottom-nav tab (Nick 2026-07-15,
  T1 20260715T1457), superseding the 2026-07-14 "Settings as a dismissable sheet / three
  content tabs" decision. Device management is NOT its own tab: it lives inside Settings
  as a "Devices & connections" page, so there is one management home, not a competing tab.

  Scenario: the app shows Capture, Activity, Chat, Settings tabs in order
    When the app shell is presented
    Then the bottom tab bar shows exactly "Capture", "Activity", "Chat", "Settings" in that order
    And the Capture tab is selected

  Scenario: Settings is a tab and Device is not
    When the app shell is presented
    Then a tab is labelled "Settings"
    And no tab is labelled "Device"

  Scenario: Device management lives inside Settings
    When I open the Settings tab
    Then I see a "Devices & connections" entry that opens the device page

  Scenario: the Capture screen has no header settings gear
    When the app shell is presented
    Then the Capture screen shows no settings gear in its header
    And I reach Settings by tapping the Settings tab
