Feature: Actions know who said them
  As the person wearing the recorder,
  I want every surfaced action attributed to whoever actually said it — and my
  own list to hold only what I said —
  so other people's remarks stop showing up as my to-dos.

  Scenario: An action I said reads "You said"
    Given a conversation where the transcript attributes the surfaced line to me
    When I look at the conversation's actions
    Then the action appears in my actions
    And its attribution reads "You said"

  Scenario: An action someone else said collects under "Heard from others"
    Given a conversation where the transcript attributes the surfaced line to "Sarah"
    When I look at the conversation's actions
    Then the action is not in my actions
    And it appears under "Heard from others"
    And its attribution reads "Sarah said"

  Scenario: An unnamed voice's action reads "Unknown speaker"
    Given a conversation where I am identified and an unnamed voice said the surfaced line
    When I look at the conversation's actions
    Then the action is not in my actions
    And it appears under "Heard from others"
    And its attribution reads "Unknown speaker"

  Scenario: Before speakers are identified, my list keeps the action and says so
    Given a conversation whose speakers are not identified yet
    When I look at the conversation's actions
    Then the action appears in my actions
    And its attribution reads "Speaker not identified yet"

  Scenario: When speakers arrive, someone else's action moves out of my list
    Given a conversation whose speakers are not identified yet
    And the action appears in my actions
    When the transcript later attributes the surfaced line to "Sarah"
    And I look at the conversation's actions
    Then the action is not in my actions
    And it appears under "Heard from others"

  Scenario: A line the transcript cannot place stays in my list, honestly labeled
    Given a conversation with identified speakers whose transcript does not contain the surfaced line
    When I look at the conversation's actions
    Then the action appears in my actions
    And its attribution reads "Speaker unclear"

  Scenario: An unnamed voice stays in my list when I am not identified either
    Given a conversation where nobody is identified and an unnamed voice said the surfaced line
    When I look at the conversation's actions
    Then the action appears in my actions
    And its attribution reads "Speaker unclear"

  Scenario: A tentatively identified voice labels the action but keeps it in my list
    Given a conversation where the transcript tentatively attributes the surfaced line to "Sarah"
    When I look at the conversation's actions
    Then the action appears in my actions
    And its attribution reads "Possibly Sarah said"

  Scenario: Promoting an action from "Heard from others" into my actions
    Given an action from "Sarah" sits under "Heard from others"
    When I promote it to my actions
    Then the action appears in my actions
    And its attribution reads "Sarah said"
    And it stays in my actions when the actions are rebuilt from disk

  Scenario: Turning on "Actions from others" shows everyone's actions inline
    Given an action from "Sarah" sits under "Heard from others"
    When I turn on "Actions from others"
    Then the action appears in my actions
    And its attribution reads "Sarah said"

  Scenario: Rejecting someone else's action records who said it
    Given an action from "Sarah" sits under "Heard from others"
    When I mark it as not an action
    Then the recorded feedback carries the speaker "Sarah", not me

  Scenario: Rejecting my own action records that I said it
    Given a conversation where the transcript attributes the surfaced line to me
    When I mark it as not an action
    Then the recorded feedback carries my own voice
