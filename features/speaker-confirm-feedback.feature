Feature: Saving a speaker's name is instant and syncs quietly in the background
  As someone tagging who spoke in a conversation,
  I want my save to apply on my phone the instant I tap it and reach my computer on its own,
  so a momentary disconnect never blocks me or throws a scary error.

  Scenario: Tapping save responds immediately
    Given a conversation with a tentatively matched speaker
    When I tap to save that speaker
    Then the save shows progress immediately, before my computer has answered

  Scenario: Saving with the computer unreachable still succeeds instantly
    Given a conversation with a tentatively matched speaker
    And my computer cannot be reached
    When I save a name for the speaker from the sheet
    Then the save succeeds right away and the sheet dismisses itself
    And the saved name shows in the conversation immediately

  Scenario: Renaming a mismatched speaker records the typed name, not the old guess
    Given a conversation with a tentatively matched speaker
    And my computer cannot be reached
    When I save a name for the speaker from the sheet
    Then the saved change records only the typed name so my computer honors it

  Scenario: A saved name survives relaunch before it has synced
    Given a conversation with a tentatively matched speaker
    And my computer cannot be reached
    When I save a name for the speaker from the sheet
    And the app relaunches before the change has synced
    Then the saved name still shows in the conversation
    And the change is still waiting to sync

  Scenario: A change waiting to sync shows a quiet indicator and no error
    Given a conversation with a tentatively matched speaker
    And my computer cannot be reached
    When I save a name for the speaker from the sheet
    Then the speaker shows a quiet waiting-to-sync indicator
    And no error is shown anywhere

  Scenario: The computer's acknowledgement clears the waiting indicator
    Given a conversation with a tentatively matched speaker
    And a saved name is waiting to sync
    When my computer acknowledges the change
    Then the waiting-to-sync indicator is gone
    And the change is no longer pending on my phone

  Scenario: A sync retry that still can't reach the computer shows no error
    Given a saved name is waiting to sync
    And my computer cannot be reached
    When the phone retries the pending change
    Then no error is shown anywhere
    And the change stays pending on my phone so it ships later

  Scenario: An expired sign-in asks me to reconnect instead of retrying forever
    Given speaker changes are waiting to sync on my phone
    And my sign-in to the computer has expired
    When the phone retries the pending changes
    Then the retry stops and requests re-authentication
    And the pending changes are kept for after I sign in again

  Scenario: The computer rejecting a change reverts it gently
    Given a conversation with a tentatively matched speaker
    And a saved name is waiting to sync
    When my computer rejects the change
    Then the change is no longer pending on my phone
    And I see a gentle notice that it was reverted, not an error dialog

  Scenario: An acknowledgement that matches past conversations offers to apply
    Given a conversation with a tentatively matched speaker
    And a saved name is waiting to sync
    When my computer acknowledges the change and it matches past conversations
    Then I am offered to apply the name to those past conversations
