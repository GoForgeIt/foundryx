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
    Then the first card reads "Sent to chat"
    And the second card reads "Dismissed"
    And the third card shows it is still waiting on me

  Scenario: An action card knows which conversation it came from
    Given an action that surfaced during a conversation
    Then its card carries a link back to that conversation

  Scenario: A conversation with no actions says so honestly
    Given a conversation during which nothing actionable surfaced
    When I open the Actions face
    Then I see that nothing actionable came up, not an error
