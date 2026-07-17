Feature: Acting on a surfaced action
  As someone reviewing what a conversation surfaced,
  I want to act on an action in chat, reject it, or refine it with a note,
  so the assistant executes for me and its action spotter learns from my feedback.

  Scenario: Tapping an action offers ways to act on it
    Given a conversation that surfaced an action
    When I look at the action's options
    Then I can act on it in chat, mark it as not an action, or refine it

  Scenario: Acting on it in chat pre-fills the chat with the action's context
    Given a conversation that surfaced an action
    When I choose to act on it in chat
    Then the chat opens pre-filled with what was heard and what could be done
    And the action reads as sent to chat

  Scenario: Marking an action as not an action with a comment
    Given a conversation that surfaced an action
    When I mark it as not an action with the comment "that was just small talk"
    Then the action shows "Not an action"
    And my rejection and comment are recorded for the action spotter to learn from

  Scenario: A rejection needs no comment
    Given a conversation that surfaced an action
    When I mark it as not an action without a comment
    Then the action shows "Not an action"
    And the rejection is recorded for the action spotter to learn from

  Scenario: Refining an action with a note
    Given a conversation that surfaced an action
    When I refine it with the comment "it is about the Q3 deck, not Q2"
    Then the action stays open and shows my note
    And my refinement is recorded for the action spotter to learn from

  Scenario: Refining after acting keeps what already happened
    Given a conversation that surfaced an action that I sent to chat
    When I refine it with the comment "next time include the deadline"
    Then the action still reads as sent to chat
    And my refinement is recorded for the action spotter to learn from

  Scenario: Feedback survives a fresh look
    Given I marked an action as not an action with a comment
    When the actions are rebuilt from disk
    Then the action still shows "Not an action"
    And the recorded feedback still carries my comment

  Scenario: A hand-added action can be taken to chat too
    Given a conversation where I added my own action
    When I choose to act on it in chat
    Then the chat opens pre-filled with my action

  Scenario: A quiet conversation offers nothing to act on
    Given a conversation that surfaced nothing
    Then there are no actions to act on
