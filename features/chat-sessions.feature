Feature: FoundryX chat is session-based with model selection

  The FoundryX chat surface keeps a list of resumable conversations instead of one
  eternal thread. Starting a new chat mints a fresh session id (the kiln-session
  chat_id), each conversation retains its own history, and switching between them
  restores that history. A model picker lets the user choose which model answers a
  turn — defaulting to the Kiln router (no model specified) but allowing a specific
  model, which rides through to the door as the turn's requested target. Driven
  against the REAL ChatConversationStore and the REAL ChatRequest encoding — no mocks.

  Scenario: starting a new chat creates a distinct session
    Given a conversation store with one existing conversation
    When I start a new chat
    Then the new conversation has a chat id distinct from the existing one
    And the new conversation's chat id is not the legacy "ios" id

  Scenario: switching between chats preserves each chat's history
    Given two conversations each with their own messages
    When I switch from the first conversation to the second and back
    Then each conversation still shows its own original messages

  Scenario: selecting a specific model passes it as the turn's requested target
    Given a conversation with the model "local-qwen3-8b" selected
    When I build a chat request for that conversation
    Then the chat request's requested_target is "local-qwen3-8b"
    And the chat request carries that conversation's chat id

  Scenario: the default model is the Kiln router
    Given a conversation with no model selected
    When I build a chat request for that conversation
    Then the chat request omits requested_target so the router decides
