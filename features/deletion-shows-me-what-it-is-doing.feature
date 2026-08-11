Feature: Deleting my account shows me what it is doing
  Erasing an account walks a long list of named steps — signing out on this
  device, clearing the widget, closing open activity, erasing recordings — and
  every one of them can refuse. What the app showed was a single spinner over the
  whole screen, and when it refused, one line: "deletion is incomplete at
  preparing: exposureBarrierFailed".

  "preparing" is not a step. It is the fallback used when nothing knew which step
  had failed. So the person is told an irreversible operation on their own data
  did not finish, is not told what did or did not get erased, and is given an
  error string aimed at a programmer with no action attached to it.

  Scenario: I watch the erase move through its steps
    Given I am deleting my account
    Then I am told the erase is starting
    When the erase reaches "closing open account activity"
    Then that step is shown as in progress
    And "signing out on this device" is shown as finished
    And "erasing recordings and transcripts" is shown as not started

  Scenario: Finishing tells me it finished
    Given I am deleting my account
    When the erase finishes
    Then every step is shown as finished
    And I am told everything on this iPhone was erased

  Scenario: A refusal names the step that refused
    Given I am deleting my account
    When the erase reaches "erasing pairing secrets"
    And that step refuses because it could not be saved
    Then I am told which step did not finish
    And that step is shown as failed
    And the steps after it are shown as not started
    And I am offered a way to try again

  # The exact failure Nick was shown. It must never again be reported against a
  # step that does not exist.
  Scenario: A refusal with no step of its own is blamed on the step that was running
    Given I am deleting my account
    When the erase reaches "closing open account activity"
    And the erase refuses without naming a step
    Then I am told which step did not finish
    And the step I am told about is "closing open account activity"
    And I am not shown an indefinite spinner

  # A retry button that can never succeed is worse than no button. This refusal
  # happens before any step runs, so there is no step to name — but there is
  # still something specific to say and something specific to do.
  Scenario: A refusal that retrying cannot fix does not offer a retry
    Given I am deleting my account
    When the erase refuses because this iPhone cannot prove who owns the data
    Then I am told what stopped the deletion
    And I am told to sign in again
    And I am not offered a way to try again
    And I am not shown an indefinite spinner
