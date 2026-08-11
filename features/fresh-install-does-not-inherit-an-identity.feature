Feature: Reinstalling the app does not hand me the previous account
  Deleting an app removes everything it wrote in its own container. It does NOT
  remove what that app put in the device keychain — iOS keeps those on purpose,
  so a reinstalled app can find its old credentials.

  On TestFlight 771837 Nick deleted the app, reinstalled it from TestFlight, and
  was still signed in as the previous account. "Delete everything now" followed
  by a full reinstall still left the identity on the phone. This app holds
  recordings and transcripts of real conversations, so an identity that outlives
  the app is a data-remanence bug.

  The same asymmetry is the fix: the container IS wiped on uninstall, so a marker
  written into it answers "did my container survive?".

  Scenario: A reinstalled app does not inherit the previous sign-in
    Given a sign-in credential from a previous install is still on this device
    And this is the first launch after installing the app
    When the app checks for an inherited identity at launch
    Then the inherited sign-in credential is gone from the device
    And the device is recorded as signed out
    And the previous install's pairing secrets are gone from the device

  # THE DANGEROUS ONE. Getting this branch wrong signs every user out on every
  # launch, which is far worse than the bug being fixed.
  Scenario: An ordinary launch of an installed app erases nothing
    Given I signed in on a previous launch of this same install
    When the app checks for an inherited identity at launch
    Then nothing is erased
    And I am still signed in
    And the app recognised this install without inspecting the keychain

  # Every install already on a phone predates the marker. Without this branch,
  # the update that ships the fix would sign the whole fleet out once.
  Scenario: Updating from a build without the launch check erases nothing
    Given I signed in on a build that predates the first-launch check
    When the app checks for an inherited identity at launch
    Then nothing is erased
    And I am still signed in
    And this install is recorded so the check settles for good

  # "I cannot read the keychain" is not "the keychain is empty" — a background
  # relaunch on a locked phone must not be recorded as a finished check.
  Scenario: A locked device is checked again next launch instead of guessed at
    Given a sign-in credential from a previous install is still on this device
    And this is the first launch after installing the app
    And the device is locked so the keychain cannot answer
    When the app checks for an inherited identity at launch
    Then nothing is erased
    And the inherited sign-in credential is still on the device
    And the check runs again on the next launch
