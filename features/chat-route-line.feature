Feature: The chat header opens, names the router, and reports what answered

  Tapping "Auto" in the chat header did nothing, because there was nothing there to
  tap: the control had been reduced to a plain line of text with no Button and no Menu
  around it. Two more things were wrong with the words it showed. "Auto" is not the
  name of anything — the default IS Kiln's router, and a header that will not say so
  leaves the reader guessing. And the word was derived from what the chat had been
  ASKED to use (`Conversation.modelTargetId`), never from what actually answered — so
  when a turn served by Fireworks gpt-oss-120b introduced itself as Claude, nothing on
  screen could contradict it.

  The resolved route is not missing from the wire. Kiln emits it as a boundary
  (`routed: <committed_target_id>`), the door forwards it, and ChatViewModel already
  stamps it onto the assistant message as `routedVia`. It was simply never rendered.

  Three things this feature holds. The default is the Kiln router, said out loud. A
  completed turn names the route that SERVED it. And a receipt beats a request
  whenever the two disagree. Driven against the REAL ChatRouteLine / ChatViewModel /
  ChatConversationStore — no mocks, no UI.

  Scenario: the default route is the Kiln router, named
    Given a chat with no model pinned and no turn answered yet
    Then the header reads "Open · Kiln router"
    And the header is not reporting a resolved route

  Scenario: a private chat still names its router
    Given a private chat with no model pinned and no turn answered yet
    Then the header reads "Private · Kiln router"

  Scenario: a completed turn names the route that served it
    Given a chat with no model pinned and no turn answered yet
    When a turn is answered by "cloud-fireworks-chat"
    Then the header reads "Open · answered by Cloud Fireworks Chat"
    And the header is reporting a resolved route

  Scenario: a resolved route beats the pin the chat asked for
    Given a chat pinned to "claude-opus-4-8"
    Then the header reads "Open · Claude Opus 4 8"
    When a turn is answered by "cloud-fireworks-chat"
    Then the header reads "Open · answered by Cloud Fireworks Chat"

  Scenario: the resolved route survives leaving the chat and coming back
    Given a chat with no model pinned and no turn answered yet
    When a turn is answered by "cloud-fireworks-chat"
    And the finished turn is recorded and the chat is reopened
    Then the header reads "Open · answered by Cloud Fireworks Chat"

  Scenario: only a route the cell has PROVED it can reach is offered as a pin
    Given the door catalog offers "claude-opus-4-8"
    And a chat with no model pinned and no turn answered yet
    When a turn is answered by "cloud-fireworks-chat"
    And the finished turn is recorded and the chat is reopened
    Then the routes offered to pin are "cloud-fireworks-chat"
    And "claude-opus-4-8" is not offered as a route to pin

  Scenario: a chat nothing has ever answered offers the router and nothing else
    Given the door catalog offers "claude-opus-4-8"
    And a chat with no model pinned and no turn answered yet
    Then there are no routes offered to pin

  Scenario: picking the router omits the requested target so Kiln decides
    Given a chat with no model pinned and no turn answered yet
    When the route picked is the Kiln router
    Then the chat request omits its requested target

  Scenario: picking a proved route pins it on the turn that follows
    Given a chat with no model pinned and no turn answered yet
    When the route picked is "cloud-fireworks-chat"
    Then the chat request's requested target is "cloud-fireworks-chat"
