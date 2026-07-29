Feature: FoundryX chat model picker groups tiers and recommends the secure router

  The chat header model picker renders whatever the door's GET /foundryx/models returns —
  soon including cloud tiers (Claude, GPT) alongside local models. It groups them by provider
  with friendly display names, and presents "Auto (router)" as the RECOMMENDED default.
  WHERE a turn's data goes is governed by the separate per-chat Privacy control, not by this
  picker: once privacy is its own control, a picker that also promises "keeps data local"
  is claiming something it does not decide, and the two can disagree. Auto is the
  default selection and omits requested_target; picking a specific model sends it as the turn's
  requested target. Driven against the REAL ModelCatalog + REAL ChatConversationStore /
  ChatRequest encoding — no mocks.

  Scenario: a heterogeneous model list groups into provider tiers in order
    Given the door offers a model list with Anthropic, OpenAI, and local entries
    When the picker menu is built from that list
    Then the provider groups are "Anthropic", "OpenAI", "Local" in that order
    And each model shows a friendly display name not its raw id

  Scenario: cloud and local ids are classified to the right provider
    Given a model id "claude-opus-4.8" labeled "Claude Opus 4.8"
    Then its provider group is "Anthropic"
    Given a model id "gpt-5.5" labeled "GPT-5.5"
    Then its provider group is "OpenAI"
    Given a model id "local-qwen3-8b" labeled ""
    Then its provider group is "Local"
    And its friendly display name is "Qwen3 8b"

  Scenario: Auto (router) is the recommended default
    Given the picker menu is built from any model list
    Then the Auto entry is marked secure and recommended
    And the Auto entry caption describes how it picks a model, not where data goes

  Scenario: an empty or unreachable door still shows Auto as the secure default
    Given the door offers no models
    When the picker menu is built from that list
    Then there are zero provider groups
    And the Auto entry is still marked secure and recommended

  Scenario: the default selection is Auto and omits the requested target
    Given a conversation with no model selected
    When I build a chat request for that conversation
    Then the chat request omits requested_target so the router decides

  Scenario: selecting a grouped model passes it as the turn's requested target
    Given a conversation with the model "claude-opus-4.8" selected
    When I build a chat request for that conversation
    Then the chat request's requested_target is "claude-opus-4.8"
