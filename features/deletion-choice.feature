Feature: Deleting my account is a choice, not one door
  The server can delete now, delete when my subscription ends, or just cancel the
  subscription and keep everything. The app only ever asked for the first, so
  someone who wanted to stop paying but keep their notes had exactly one option:
  destroy everything today and forfeit the rest of a period they already paid for.

  Leaving, economising and pausing are different intentions. The app asks which.

  Scenario: I am offered all three outcomes before anything is destroyed
    When I choose to delete my account everywhere
    Then I am offered to delete everything now
    And I am offered to delete when my subscription ends
    And I am offered to cancel my subscription and keep my data
    And nothing has been deleted yet

  Scenario: Keeping my data is not described as irreversible
    When I look at the choice to cancel my subscription and keep my data
    Then I am not warned that it cannot be undone

  Scenario: Deleting now is described as irreversible
    When I look at the choice to delete everything now
    Then I am warned that it cannot be undone

  Scenario: I am told what deleting now costs me before I confirm it
    When I look at the choice to delete everything now
    Then I am told I will not get the rest of the period back

  Scenario: Each choice asks the server for that outcome
    When I pick each deletion outcome in turn
    Then the server is asked to delete now, to delete at period end, and to cancel only

  Scenario: A scheduled deletion tells me the date
    When I choose to delete when my subscription ends
    Then I am told the date my data will be deleted
    And I am not told my account was deleted

  Scenario: Cancelling only tells me my notes are still here
    When I choose to cancel my subscription and keep my data
    Then I am told my notes are still here
    And I am not told my account was deleted

  # The live service decides this, not the screen. A scheduled deletion has
  # destroyed nothing yet and a cancel keeps everything, so wiping the device
  # for either would delete notes the person explicitly chose to keep.
  Scenario: Only deleting now wipes this phone
    When the live deletion service runs each outcome
    Then only deleting now erased this phone

  Scenario: Backing out of the choice does nothing at all
    When I open the deletion choice and back out
    Then nothing was deleted
    And no request reached the server

  Scenario: Every attempt is recorded with its outcome
    When I pick each deletion outcome in turn
    Then each attempt is recorded with the scope I chose and how it ended

  Scenario: A failure is recorded as a failure
    When a deletion fails
    Then the failure is recorded, not silently dropped

  Scenario: The record does not carry who I am or what I wrote
    When I pick each deletion outcome in turn
    Then no recorded event carries my email address or my notes
