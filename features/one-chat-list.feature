Feature: One list of chats, wherever they came from

  Nick: "why are there two lists? Shouldn't the phone chats just be another source in the
  full computer list? So they should all be one with the same ui to search through them
  all?"

  There used to be two. Then there was one control naming the two places they lived, which
  made the split legible instead of removing it. The split was the defect. Every harness is
  a SOURCE joined into one corpus — Kiln is a source, Claude Code is a source, Codex is a
  source, and the phone is just another source. So there is ONE list, ordered by recency,
  rendered by one set of rows, and where a chat came from is a facet on the row rather than
  a door onto a different screen.

  That is not a metaphor about the phone: a chat started here already appears in the Mac's
  library the moment it takes a turn, because both surfaces open-or-resume by the id this
  phone minted. The two "separate" lists always overlapped; nothing deduplicated them.

  Two things this list is never allowed to do. It must not let a search silently cover one
  origin — a phone that can only search its own rows, or only the page of the Mac's rows it
  happens to be holding, would return a partial answer that looks complete. And it must not
  present the phone's chats as everything when the computer cannot be reached. That is the
  same class as the empty-list-looks-like-no-conversations trap the door answers 502/503
  for, moved one layer out.

  Scenario: chats from this phone and from my Mac stand in one list, newest first
    Given I started a chat on this phone an hour ago
    And my Mac holds a Claude Code chat from yesterday
    And my Mac holds a Kiln chat from ten minutes ago
    When I open my chats
    Then all three chats are in one list
    And they are ordered with the most recent first

  Scenario: where each chat came from is on its own row
    Given I started a chat on this phone an hour ago
    And my Mac holds a Claude Code chat from yesterday
    When I open my chats
    Then every chat says which source it came from
    And the chat I started here says it came from this phone

  Scenario: a chat I started here that my Mac also knows about is one row, not two
    Given I started a chat on this phone an hour ago
    And my Mac already knows that same chat
    When I open my chats
    Then that chat appears exactly once
    And it is still the chat this phone can carry on locally

  Scenario: one search finds chats from both this phone and my Mac
    Given I started a chat on this phone about kestrels
    And I also started a chat on this phone about something else
    And my Mac holds a Claude Code chat about kestrels
    And my Mac holds a Codex chat about something else
    When I search for "kestrels"
    Then I find the chat I started here
    And I find the Claude Code chat from my Mac
    And I do not find either chat about something else
    And the list says it searched this phone and my Mac

  Scenario: a search reaches chats my phone was not already holding
    Given my Mac holds more chats than my phone is showing
    And the chat I am looking for is not one of the ones being shown
    When I search for it
    Then I find it
    And finding it did not depend on it already being on my phone

  Scenario: a search finds a chat by something said inside it, not just its title
    Given my Mac holds a chat whose title says nothing about kestrels
    But kestrels are discussed inside it
    When I search for "kestrels"
    Then I find that chat

  Scenario: a list showing part of my Mac's chats says so
    Given my Mac holds more chats than my phone is showing
    When I open my chats
    Then the list says how many of my Mac's chats it is showing

  Scenario: filtering by source narrows the list and says a filter is on
    Given I started a chat on this phone an hour ago
    And my Mac holds a Claude Code chat from yesterday
    When I look at only the Claude Code chats
    Then I see the Claude Code chat
    And I do not see the chat I started here
    And the list says it is showing only Claude Code
    And I can get back to every source from there

  Scenario: only sources I actually have are offered as filters
    Given I started a chat on this phone an hour ago
    And my Mac holds a Claude Code chat from yesterday
    When I open my chats
    Then this phone and Claude Code are offered as sources to filter by
    And Codex is not offered, because I have no Codex chats

  Scenario: an unreachable computer says so instead of showing my phone's chats as everything
    Given I started a chat on this phone an hour ago
    But my computer cannot be reached
    When I open my chats
    Then I still see the chat I started here
    And I am told these are the chats on this phone and my Mac isn't reachable
    And I am never shown my phone's chats as though they were all of them

  Scenario: searching while my computer is unreachable never claims to have searched it
    Given I started a chat on this phone about kestrels
    But my computer cannot be reached
    When I search for "kestrels"
    Then I find the chat I started here
    And the list says my Mac's chats were not searched

  Scenario: a search always says what it covered
    Given my Mac holds nothing but a chat about kestrels
    When I search for "kestrels"
    Then the list says what the search covered

  Scenario: with no computer and no chats at all, there is nothing to show and it says why
    Given I have no chats on this phone
    And no computer is connected
    When I open my chats
    Then I am told no computer is connected
    And I am not shown an empty list as if I had no chats

  Scenario: there is one way into my chats and it does not ask me to choose a place
    Given I am on the chat surface
    Then there is one control that opens my chats
    And it does not ask me which place to look in
    And no control on that surface opens a second list of chats

  Scenario: the list is named for what it holds, not for how much
    Given I am on the chat surface
    When I open my chats
    Then the list is not named with a bare quantifier
    And the rule that says so can actually reject one
