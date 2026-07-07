Feature: Delete a conversation everywhere

  A user can delete any conversation they don't want kept. The card disappears
  immediately; the audio, transcript, and metadata are removed from the phone,
  the desktop, and the Lore library. A deleted conversation can never
  resurrect — not from a status poll, not from a desktop retry sweep, not from
  a relaunch. Deleting while offline still hides it at once and completes the
  remote removal when the desktop is next reachable. (Design follows Omi's
  delete: instant local removal, deferred remote delete, pending-delete filter
  so refreshes can't bring the card back.)

  Scenario: deleting a conversation removes it from the list immediately
    Given a completed conversation in my list
    When I delete it and confirm
    Then its card disappears from the list immediately

  Scenario: a deleted conversation is gone after relaunch
    Given I deleted a conversation earlier
    When I relaunch the app
    Then that conversation does not appear in my list

  Scenario: deleting removes the conversation from the computer and the library
    Given a conversation that was saved to my computer and my library
    When I delete it and confirm
    Then its audio and transcript are removed from the computer
    And its content is removed from the library

  Scenario: deleting while offline still works
    Given my phone cannot reach the computer right now
    When I delete a conversation and confirm
    Then its card disappears immediately
    And the computer-side removal completes when the connection returns

  Scenario: a status refresh cannot resurrect a deleted conversation
    Given I just deleted a conversation
    When the app refreshes conversation statuses
    Then the deleted conversation stays gone
