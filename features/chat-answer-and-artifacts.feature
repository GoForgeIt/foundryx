Feature: Answers, agent runs, and their artifacts are legible

  Chat is where delegation becomes visible. An ambient answer opens as a real
  surface: the answer itself, the sources consulted from the user's own memory,
  small feedback toggles that are never pre-selected (the system never rates
  itself), a free-text note, and a one-tap way to continue the thought in a
  seeded chat session. Agent runs read as step tiles as they happen, long runs
  fold their older steps, finished runs surface findings and take a follow-up,
  and hosted runs say plainly where they run and which trial this is. Files a
  run or chat produces render in-app when we honestly can (Markdown, HTML,
  images) and say so honestly when we can't, with an export path. Artifact
  bytes ride the same door file route the app already uses for capture files.

  Scenario: the chat composer invites the user with "Ask Solleva"
    Given I open Chat
    Then the composer placeholder reads "Ask Solleva"

  Scenario: a failed send reads calmly, never a code
    Given my computer cannot be reached
    When I send a message and it fails
    Then the chat says "Your computer couldn't be reached."
    And a rejected send says "That didn't go through — try again."
    And the thread never shows "DoorError", "HTTP", or a bracketed code
    And the technical detail goes to the door log instead

  Scenario: an answer with a recommendation renders the decision brief
    Given an answer whose text carries a recommendation, why bullets, and a source
    When the answer surface opens
    Then I see a Recommendation section with the recommended call
    And the reasons render as Why bullets
    And the Source section names where it came from
    And an answer without that structure keeps the plain answer layout

  Scenario: a finished agent run folds into a finding
    Given a tool-using turn that finished with seven steps
    Then the run reads as a Finding card, not a bare done row
    And the three older steps are folded behind "3 more steps"
    And the card carries the sources-consulted line

  Scenario: an ambient answer opens with the answer and its sources
    Given an ambient answer compiled from my memory with two sources
    When the answer surface opens
    Then I see the answer text
    And I see the sources consulted
    And the surface never calls them citations

  Scenario: answer feedback starts unselected
    Given an answer surface has just opened
    Then neither Helpful nor Not useful is selected

  Scenario: tapping a feedback toggle selects it and tapping again clears it
    Given an answer surface with no feedback given
    When I tap Helpful
    Then Helpful is selected
    When I tap Helpful again
    Then neither Helpful nor Not useful is selected

  Scenario: switching feedback replaces the prior choice
    Given I rated an answer Helpful
    When I tap Not useful
    Then Not useful is selected and Helpful is not

  Scenario: I can attach a note to an answer
    Given an answer surface is open
    When I type a note about what else to pull
    Then the note is kept with my feedback

  Scenario: continuing in chat seeds a session with the answer
    Given an answer surface is open
    When I choose to continue in chat
    Then a chat session is seeded with the answer
    And my note rides along when I wrote one

  Scenario: run steps appear as tiles as they happen
    Given an agent run is in flight
    When the agent takes a step with a tool
    Then I see a step tile naming the tool action
    And once the step finishes the tile carries a one-line outcome

  Scenario: long runs fold their older steps
    Given an agent run with seven steps
    Then I see the four most recent steps
    And the three older steps are folded behind "3 more steps"

  Scenario: short runs show every step unfolded
    Given an agent run with four steps
    Then I see all four steps and nothing is folded

  Scenario: a finished run shows findings and takes a follow-up
    Given an agent run that finished
    Then I see a findings summary
    And I can send a follow-up that continues the run's session

  Scenario: hosted runs say where they run
    Given an agent run hosted on Solleva Cloud as the first of ten trials
    Then the run states "Run 1 of 10 · runs on Solleva Cloud"

  Scenario: a Markdown file from a run renders in-app
    Given a run produced a Markdown file
    When I open it
    Then it renders as formatted text in the app

  Scenario: an HTML file from a run renders in-app
    Given a run produced an HTML file
    When I open it
    Then it renders as a page in the app for display only

  Scenario: an image from a run renders in-app
    Given a run produced an image file
    When I open it
    Then I see the image in the app

  Scenario: unsupported files say so honestly and offer export
    Given a run produced a file type the app cannot render
    When I open it
    Then I see an honest note that it can't be previewed here
    And I can share or export the file

  Scenario: a missing artifact is reported honestly
    Given a run references a file the desktop no longer has
    When I open it
    Then I'm told the file isn't available rather than shown an error page

  # ── The stream announces what the agent wrote (track 20260713T1500) ──

  Scenario: a file the agent wrote arrives as an artifact in the chat
    Given a chat turn during which the agent wrote "report.md"
    Then the conversation offers "report.md" to view
    And opening it fetches the file from my desktop

  Scenario: artifacts belong to their turn
    Given a chat turn that produced an artifact
    When the next turn starts
    Then the previous turn's artifact offer is gone

  Scenario: the same artifact announced twice is offered once
    Given a chat turn during which the agent wrote "report.md" twice
    Then the conversation offers "report.md" to view once
