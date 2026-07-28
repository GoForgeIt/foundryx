Feature: Actions link to their chats, and chats know where they came from
  As someone acting on surfaced actions,
  I want every action surface to offer the same options, an acted-on action to
  lead back to its chat, and my chat list to be organized by where chats came from,
  so nothing dead-ends and the chats stay findable.

  Scenario: The Activity page offers the same action options
    Given the activity ledger shows a surfaced action
    Then the activity entry carries enough to act on it, reject it, or refine it

  Scenario: A ledger entry that is not an action offers no action options
    Given the activity ledger shows a dismissed-nudge entry
    Then that entry offers no action options

  Scenario: Acting on an action in chat remembers which chat it started
    Given a conversation that surfaced an action
    When I act on it in chat and send the turn
    Then the action is linked to that chat

  Scenario: An already-acted action leads back to its chat
    Given an action that was acted on in a chat
    When the actions are rebuilt from disk
    Then the action offers to continue in that chat instead of starting fresh

  Scenario: Deleting the chat forgets the link honestly
    Given an action that was acted on in a chat
    When that chat is deleted
    Then the action offers to act in chat afresh

  Scenario: A chat born from an action carries its origin
    Given a conversation filed under the category "MSCI-Work" that surfaced an action
    When I act on it in chat and send the turn
    Then the chat records that it came from that conversation
    And the chat records the category "MSCI-Work"
    And the chat records when it was created

  Scenario: A chat I start myself is mine
    When I start a new chat myself
    Then the chat records that I started it

  Scenario: The chat list can show only chats from conversations
    Given chats that came from conversations and chats I started myself
    When I filter the chat list to "From voice notes"
    Then only the conversation-born chats remain

  Scenario: The chat list can show only chats I started
    Given chats that came from conversations and chats I started myself
    When I filter the chat list to "Started by me"
    Then only my own chats remain

  Scenario: The chat list can filter by category
    Given conversation-born chats from the categories "Personal" and "MSCI-Work"
    When I filter the chat list to the category "Personal"
    Then only the "Personal" chats remain

  Scenario: Conversation-born chats group under their source conversation
    Given two chats born from the same conversation and one from another
    When the chat list is grouped by source
    Then the two chats sit together under their conversation
    And the third sits under its own

  Scenario: Legacy chats without provenance still load and read as mine
    Given a chat saved before provenance existed
    Then it still loads and reads as started by me
