Feature: A transfer outlives the page that asked for it
  The queue was written, proven and shipped with NO production caller — the recorder page still
  owned its transfer as a task on a screen, under an `.onDisappear` that cancelled it, so
  walking away during a pull measured at 18-36 KB/s killed the pull. Wiring the page to the
  queue is three decisions, and all three used to live where nothing in this repository could
  execute them: what leaving the page does, what a finished transfer obliges the running app to
  do, and which of the readings the radio produces is worth waking a screen for.

  Scenario: Leaving the page stops a check and leaves a transfer running
    Given a shelf check, a durable transfer and the WiFi fast sync, each in flight in turn
    When the owner leaves the page during each of them
    Then the shelf check is stopped
    And the durable transfer is left running
    And the fast sync is stopped, because it is not a durable job
    And a page with nothing running still answers stop

  Scenario: A finished transfer hands its conversation over and repeats what the clock said
    Given every way one queued recording can end
    When each ending is put to the follow-through
    Then only the endings that moved custody hand a conversation to the running app
    And the sentence for a finished transfer carries the recorder's clock warning
    And every ending closes the errand with its own token
    And a recording still in flight closes no errand at all

  Scenario: A screen is woken once per whole percent, not once per notification
    Given the readings a long transfer produces at the captured chunk sizes
    When every reading is offered to the screen
    Then the screen is woken once per whole percent and no more
    And the first reading and the last reading both reach it
    And a reading that is not progress always reaches it
