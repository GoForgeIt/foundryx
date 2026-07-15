Feature: Conversation detail with three faces and transcript search
  As someone reviewing a captured conversation,
  I want its detail split into summary, actions, and transcript,
  with search inside the transcript,
  so I can find what was said and see what came of it.

  Scenario: A conversation opens into three faces
    Given a conversation that has been transcribed
    When I open the conversation
    Then I can switch between its Summary, Actions, and Transcript faces
    And the Summary face is shown first

  Scenario: The summary face shows the summary and metadata
    Given a transcribed conversation with a summary
    When I open the conversation
    Then I see the summary, when it happened, and where

  @faces
  Scenario: The summary face says what mattered
    Given a transcribed conversation whose summary covers several points
    When I open the Summary face
    Then I see a "What mattered" list with one bullet per point

  @faces
  Scenario: The summary face links to the relay answer
    Given a conversation that has been transcribed
    And an ambient answer surfaced from this conversation
    When I open the Summary face
    Then I can open the relay answer from the summary

  @faces
  Scenario: A conversation without a linked answer offers no answer row
    Given no ambient answer surfaced from this conversation
    When I open the Summary face
    Then there is no answer row to open

  Scenario: Searching the transcript highlights matches and shows the count
    Given a conversation whose transcript mentions "budget" three times
    When I search the transcript for "budg"
    Then all three mentions are highlighted
    And I see that I am on the first of three matches

  Scenario: Search matches regardless of letter case
    Given a conversation whose transcript says "Budget review on Friday"
    When I search the transcript for "budget"
    Then the mention is highlighted and counted

  Scenario: Next and previous step through the matches
    Given I searched the transcript and there are three matches
    When I step to the next match
    Then I am on the second of three matches
    When I step forward past the last match
    Then I am back on the first match
    When I step backward from the first match
    Then I am on the last match

  Scenario: Clearing the search removes the highlights
    Given I searched the transcript and matches are highlighted
    When I clear the search
    Then no text is highlighted and no match count shows

  Scenario: A search with no matches says so honestly
    Given a conversation whose transcript never mentions "regatta"
    When I search the transcript for "regatta"
    Then I see that there are no matches
    And stepping to the next or previous match does nothing

  Scenario: Meaning search is offered only when the phone can actually do it
    Given no meaning index exists for the conversation
    When I open the Transcript face
    Then there is no meaning toggle anywhere

  Scenario: Meaning search appears when an index is available
    Given a meaning index is available for the conversation
    When I open the Transcript face
    Then I can switch the search between text and meaning

  Scenario: Action cards show what came of them
    Given the conversation surfaced an action that I sent to chat
    And the conversation surfaced an action that I dismissed
    And the conversation surfaced an action I have not decided on
    When I open the Actions face
    Then the first card shows it was completed
    And the second card reads "Dismissed"
    And the third card shows it is still open

  @faces
  Scenario: The actions face is populated from what actually surfaced
    Given the conversation surfaced an action that I sent to chat
    And an ambient answer surfaced from this conversation
    And the conversation surfaced an action I have not decided on
    When I open the Actions face
    Then I see rows marked Completed, Ready, and Open

  @faces
  Scenario: I can add an action to a conversation
    Given a conversation during which nothing actionable surfaced
    When I add an action "Send Sarah the deck"
    Then the Actions face lists "Send Sarah the deck" as an open item
    And it is still there when I come back

  Scenario: An action card knows which conversation it came from
    Given an action that surfaced during a conversation
    Then its card carries a link back to that conversation

  @faces
  Scenario: A conversation with no actions says so honestly
    Given a conversation during which nothing actionable surfaced
    When I open the Actions face
    Then I see that nothing surfaced from this conversation yet, not an error
    And I can still add an action

  @faces
  Scenario: The detail faces show no processing stepper
    Given a conversation that is still being processed
    When I open the conversation
    Then no processing stepper appears in any face
