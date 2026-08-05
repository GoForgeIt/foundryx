Feature: I can find the chats that live on my Mac

  The phone can already reach every chat Kiln holds on the Mac — its own, and every Claude
  Code and Codex transcript it imported. But the way in was a text button labelled "All",
  sitting immediately beside a text button labelled "Chats". Two short, quantifier-shaped
  siblings read as a filter pair over one list, not as doors onto two different bodies of
  work — and the sheet behind "Chats" has its own "All" chip, so the same word appeared
  twice on one screen meaning two unrelated things.

  So someone looking for their desktop chats opened the obvious one, saw the handful this
  phone had started, and concluded the feature had never shipped. It had. They had opened
  the other door.

  There is now ONE way in, and it names the two places rather than counting them. This is a
  legibility change: nothing about either corpus, its grouping, or picking a chat back up
  behaves differently.

  Scenario: one control decides which chats I am looking at
    Given I am on the chat surface
    Then there is a single control for choosing which chats to look at
    And it does not sit beside a second control that opens chats

  Scenario: the choice names the two places my chats live
    Given I am on the chat surface
    When I open the control for choosing which chats to look at
    Then I can choose the chats on this phone
    And I can choose the chats on my Mac
    And neither choice is labelled with a bare quantifier

  Scenario: each choice says what is behind it before I commit to it
    Given I am on the chat surface
    When I open the control for choosing which chats to look at
    Then every choice says what I would be looking at
    And the choice for my Mac names Kiln, Claude Code and Codex

  Scenario: "All" means only one thing on the chat surface
    Given I am on the chat surface
    Then no control on that surface is labelled "All"
    But "All" is still offered as a filter over the chats this phone started

  Scenario: the library I land on says whose chats it is showing
    Given I am on the chat surface
    When I choose the chats on my Mac
    Then the screen I land on is titled for my Mac
    And it is not titled with a bare quantifier

  Scenario: an imported chat still shows me how to pick it back up
    Given Kiln's library holds a chat imported from Claude Code that I have not picked up
    Then that chat is marked as one I can pick up
    And opening it offers to pick it back up where it left off
    And a chat I already picked up is not offered again
