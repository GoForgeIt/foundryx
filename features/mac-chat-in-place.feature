Feature: A chat from my Mac opens and continues in place

  The phone could already LIST the chats on my Mac. Opening one was another matter: it built
  every turn at once, so a long one took seconds to paint and then landed at the very top —
  at the oldest thing anyone had said — with no way to get to the bottom. And where the
  composer should have been there was a button, so the phone read as if a chat from my Mac
  were a document to be claimed rather than a chat to be continued.

  Measured on the real library: the largest chat holds 42,311 turns. Building all of them
  took 22.8 seconds and then died; building the newest forty took 69 milliseconds. Fetching
  and decoding those 44 MB took 122 ms — under one percent of it. The cost was never the
  network. It was building turns nobody had scrolled to.

  So: a chat from my Mac is a chat. Same surface, same bubbles, same composer. It opens where
  I left off, it opens quickly however long it is, and continuing it is typing into it.

  Scenario: A chat from my Mac opens on its newest turn
    Given my computer is connected
    And a chat on my Mac that I have been going back and forth in
    When I open that chat on my phone
    Then it opens on the newest thing that was said
    And it does not open on the oldest

  Scenario: A chat of tens of thousands of turns opens without building all of them
    Given my computer is connected
    And a chat on my Mac holding tens of thousands of turns
    When I open that chat on my phone
    Then only a small window of the newest turns is built
    And the rest are held back rather than built

  Scenario: The earlier turns are still there when I ask for them
    Given my computer is connected
    And a chat on my Mac holding tens of thousands of turns
    When I open that chat on my phone
    And I ask for earlier turns
    Then more of the earlier turns are built
    And asking enough times reaches the very first thing that was said

  Scenario: Typing is how I continue a chat brought over from another tool
    Given my computer is connected
    And a chat on my Mac brought over from Claude Code that I have never picked up
    When I open that chat on my phone
    And I type into it and send
    Then it is picked back up for me without my having asked separately
    And what I typed is sent into that same chat

  Scenario: Continuing keeps the chat I was in rather than starting another
    Given my computer is connected
    And a chat on my Mac brought over from Claude Code that I have never picked up
    When I open that chat on my phone
    And I type into it and send
    Then everything went to the id of the chat I was reading
    And a reply naming some other chat is refused

  Scenario: A chat that is already live is not picked up a second time
    Given my computer is connected
    And a chat on my Mac that is already live in Kiln
    When I open that chat on my phone
    And I type into it and send
    Then nothing is picked up, because it already was
    And what I typed is sent into that same chat

  Scenario: Sending twice picks the chat up once
    Given my computer is connected
    And a chat on my Mac brought over from Claude Code that I have never picked up
    When I open that chat on my phone
    And I type into it and send
    And I type into it and send again
    Then it was picked back up exactly once
    And both of the things I typed were sent

  Scenario: A chat from my Mac and a chat from my phone are one chat surface
    Given my computer is connected
    And a chat on my Mac and a chat that started on my phone, saying the same things
    When I open each of them
    Then both render through the same chat surface
    And neither screen builds a chat surface of its own

  Scenario: A chat I could not read is not shown to me as an empty chat
    Given my computer is connected
    But that chat cannot be read
    When I open that chat on my phone
    Then I am told it could not be read
    And I am never shown it as a chat where nothing was said
