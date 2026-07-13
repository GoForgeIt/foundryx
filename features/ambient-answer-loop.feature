Feature: The answer loop closes

  An answer compiled from my memory is not a dead end: delivering it is
  remembered in my activity, tapping its notification opens the full answer
  surface, the rating I give lands on that answer in the ledger, and an agent
  run that finishes in chat is remembered too. Nothing rates itself and
  nothing is invented: entries exist only because a writer recorded a real
  event.

  Scenario: a delivered answer is remembered in my activity
    Given an ambient lookup found an answer in my memory
    When the answer notification is delivered
    Then the activity ledger shows the answer
    And it links back to the conversation it came from

  Scenario: tapping an answer notification opens the answer surface
    Given an answer notification is on my lock screen
    When I tap it
    Then the answer surface opens with the answer text

  Scenario: my rating lands on the answer in the ledger
    Given the ledger shows an answer
    When I rate it helpful on the answer surface
    Then the ledger's answer entry carries my rating
    And the rating is not a separate ledger entry

  Scenario: a finished agent run is remembered in my activity
    Given a chat turn where the agent used tools
    When the turn completes
    Then the activity ledger shows the agent run
    And a turn with no tool use is not recorded as a run

  Scenario: long tool runs stay readable in chat
    Given a chat turn where the agent used seven tools
    Then the chat shows the latest steps and folds the rest behind a count
