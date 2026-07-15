Feature: The app shell is four tabs with Settings as a sheet

  One bottom tab bar, exactly four tabs — Capture, Activity, Chat, Device — with
  Capture as the launch tab. Activity is first-class: one tap from anywhere.
  Settings is not a tab; a gear in the Capture and Activity top bars opens it as
  a dismissable sheet with an X close. Joining the Foundry Cloud waitlist never
  silently no-ops: a signed-out user is asked to sign in first, and the join
  fires once they have.

  Scenario: the app shows Capture, Activity, Chat, Device tabs in order
    Given the app is launched
    Then the bottom tab bar shows exactly "Capture", "Activity", "Chat", "Device" in that order
    And the Capture tab is selected

  Scenario: there is no Settings tab
    Given the app is launched
    Then no tab is labelled "Settings"

  Scenario: Activity is reachable in one tap from the tab bar
    Given I am on the Capture tab
    When I tap the Activity tab
    Then the Activity surface shows

  Scenario: Settings opens as a dismissable sheet with an X close
    Given I am on the Capture or Activity tab
    When I tap the settings gear in the top bar
    Then Settings opens as a sheet titled "Settings"
    And an X labelled "Close Settings" dismisses it

  Scenario: a local user with no id token can join the cloud waitlist
    Given I am a phone-only user with no id token
    When I tap the cloud waitlist button
    Then the sign-in sheet is presented first
    And the waitlist join fires after I sign in

  Scenario: dismissing the sign-in leaves an honest caption
    Given I am a phone-only user with no id token
    And I tapped the cloud waitlist button
    When I dismiss the sign-in sheet without signing in
    Then the button shows a "Sign in to join" caption
