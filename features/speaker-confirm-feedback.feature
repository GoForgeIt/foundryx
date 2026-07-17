Feature: Confirming a speaker gives immediate, honest feedback
  As someone tagging who spoke in a conversation,
  I want every confirm or save to respond the instant I tap it,
  so I always know whether my change was applied, is still in flight, or failed.

  Scenario: Tapping confirm shows progress immediately
    Given a conversation with a tentatively matched speaker
    When I tap the confirm affordance for that speaker
    Then the confirm shows an in-flight state before the computer has answered

  Scenario: A successful confirm shows a confirmation
    Given a conversation with a tentatively matched speaker
    And my computer acknowledges the confirmation
    When I tap the confirm affordance and the round trip completes
    Then I see a confirmed state for that speaker
    And the change is no longer pending on my phone

  Scenario: A successful confirm from the tag sheet closes the sheet
    Given the tag-speaker sheet is open for a tentatively matched speaker
    And my computer acknowledges the confirmation
    When I confirm the speaker from the sheet and the round trip completes
    Then the sheet dismisses itself

  Scenario: Saving a name closes the sheet on success
    Given the tag-speaker sheet is open for an unnamed speaker
    And my computer acknowledges the confirmation
    When I save a name for the speaker and the round trip completes
    Then the sheet dismisses itself

  Scenario: An unreachable computer keeps the change safe and says so
    Given a conversation with a tentatively matched speaker
    And my computer cannot be reached
    When I tap the confirm affordance and the round trip completes
    Then I see an honest failure that says the change is saved on my phone
    And the change stays pending on my phone so it ships later
    And I am offered a retry

  Scenario: A confirm that hangs never leaves a dead button
    Given a conversation with a tentatively matched speaker
    And my computer accepts the request but the answer never arrives
    When I tap the confirm affordance and wait past the deadline
    Then the confirm resolves to an honest unreachable failure
    And the change stays pending on my phone so it ships later

  Scenario: A rejected confirm surfaces the failure instead of faking success
    Given a conversation with a tentatively matched speaker
    And my computer rejects the confirmation
    When I tap the confirm affordance and the round trip completes
    Then I see an honest failure, not a confirmed state

  Scenario: An expired sign-in asks me to reconnect instead of retrying forever
    Given speaker confirms are pending on my phone
    And my sign-in to the computer has expired
    When the phone retries the pending confirms
    Then the retry stops and requests re-authentication
    And the pending confirms are kept for after I sign in again
