Feature: Coming back to the app continues where I was
  As someone who leaves FoundryX mid-thought and comes back,
  I want to land on the page I was on with what I had open still open,
  so returning continues my work instead of restarting me at the list.

  Scenario: leaving and returning keeps me on the same conversation
    Given I am in a chat conversation
    When I leave the app and come back
    Then I am on the Chat tab
    And the same chat conversation is open
    And I am not told anything went wrong

  Scenario: leaving and returning keeps me inside the transcript I was reading
    Given I am reading a conversation's transcript
    When I leave the app and come back
    Then I am on the Capture tab
    And the same conversation's transcript is still open

  Scenario: being reclaimed in the background is not a reason to lose my place
    Given I am reading a conversation's transcript
    When the app is reclaimed in the background and I open it again
    Then I am on the Capture tab
    And the same conversation's transcript is still open

  Scenario: leaving and returning keeps the sheet I had open
    Given I have my chat list open over the Chat tab
    When I leave the app and come back
    Then I am on the Chat tab
    And my chat list is still open

  Scenario: a conversation that was deleted while I was away drops me on the list
    Given I am reading a conversation's transcript
    When that conversation is deleted while I am away
    And I come back
    Then I am on the Capture tab
    And no transcript is open
    And I am told "That conversation isn't here anymore, so this is the list."

  Scenario: a chat that was deleted while I was away drops me on my chats
    Given I am in a chat conversation
    When that chat is deleted while I am away
    And I come back
    Then I am on the Chat tab
    And no chat conversation is open
    And I am told "That chat isn't here anymore, so this is your chats."

  # SUPERSEDES "my computer's chats do not reopen onto an unreachable computer".
  #
  # That scenario closed the sheet, because the sheet WAS the Mac's library and without a
  # Mac it was an empty shell. The sheet is now the one chat list, which holds this phone's
  # chats too and says out loud when the Mac's are missing from it — so closing it would
  # take someone's place away and show them LESS truth, not more. The harm the old scenario
  # guarded against (coming back to an empty shell) is now guarded by the list itself, and
  # this scenario asserts that guard directly rather than by removing the destination.
  Scenario: my chat list reopens even when my computer is unreachable, and says so
    Given I have my chat list open over the Chat tab
    When my computer is unreachable and I come back
    Then I am on the Chat tab
    And my chat list is still open
    And the list I come back to is not an empty shell
    And the list I come back to says my Mac's chats are missing from it
    And I am not told anything went wrong

  # The sheet used to be "my computer's chats" and is now the one list that holds both.
  # Someone upgrading with it open must not have it silently closed by the rename.
  Scenario: a place remembered before the two lists became one still reopens the list
    Given the app remembered my place while that sheet was still my computer's library
    When I leave the app and come back
    Then I am on the Chat tab
    And my chat list is still open

  Scenario: switching where my conversations live drops me on the list
    Given I am reading a conversation's transcript on my computer's brain
    When I come back on just my phone
    Then I am on the Capture tab
    And no transcript is open
    And I am told "Where your conversations live changed, so this is the list."

  Scenario: another account never inherits my place
    Given I am reading a conversation's transcript
    When a different account signs in and comes back
    Then I am on the Capture tab
    And no transcript is open
    And no chat conversation is open

  Scenario: a first launch has no place to keep and says nothing
    Given I have never used the app before
    When I open the app
    Then I am on the Capture tab
    And I am not told anything went wrong

  Scenario: my place is kept where only my account can read it
    Given I am in a chat conversation
    Then my place is stored inside my own account's folder

  Scenario: a refreshed sign-in rebuilds the whole tab tree
    Given I am on the Chat tab on my computer's brain
    When my sign-in token is refreshed
    Then the tab tree is rebuilt from scratch
    And my place is restored anyway
