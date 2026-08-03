Feature: My conversations follow me onto my phone
  I can run a conversation in Claude Code, pick it up in Kiln, and pick it back up in Claude
  Code. FoundryX should be one more place I can pick it up — routing through Kiln, over the
  same shared store the Mac already reads. Until now the phone could only ever see chats it
  itself created, because the only thing it could call opened-or-resumed by a key only the
  phone mints.

  Two things have to be true for that to be worth anything. The library has to GROUP the way
  Kiln's desktop rail groups — the same collapses, the same Inbox, the same order — or the
  two surfaces are showing me different libraries and I stop trusting either. And it has to
  be HONEST about not being able to ask: an empty list reads as "you have no conversations",
  which is the worst possible thing to say to someone whose Mac is asleep.

  Scenario: The phone lists a Claude Code conversation it never created
    Given my computer is connected
    And Kiln's library holds a conversation imported from Claude Code
    When I open the Kiln library on my phone
    Then I see that Claude Code conversation
    And it is marked as having come from Claude Code

  Scenario: An imported conversation is offered a pick-up, and picking it up keeps its id
    Given my computer is connected
    And Kiln's library holds a conversation imported from Claude Code
    When I open the Kiln library on my phone
    Then that conversation offers to be picked up
    And picking it up resumes that same conversation rather than starting a new one

  Scenario: A conversation already picked up is not offered a second pick-up
    Given my computer is connected
    And Kiln's library holds an imported conversation I already picked up
    When I open the Kiln library on my phone
    Then that conversation is not offered a pick-up
    But it still says it came from Claude Code

  Scenario: A recurring job's many firings collapse to one row that says how many
    Given my computer is connected
    And a recurring job has fired many times, each firing its own conversation
    When I open the Kiln library on my phone
    Then I see one row for that job, not one per firing
    And the row I see is the most recent firing
    And the row says how many firings it stands for
    And the job's row is not sitting in my Inbox, even though nothing else filed it

  Scenario: A subagent's conversation does not stand alone in the library
    Given my computer is connected
    And a conversation spawned a subagent that had its own conversation
    When I open the Kiln library on my phone
    Then the subagent's conversation is not a row of its own
    And the conversation that spawned it says it has work underneath it

  Scenario: A fork is not mistaken for a subagent's conversation
    Given my computer is connected
    And one conversation was forked from another
    And a different conversation spawned a subagent
    When I look at the library by lineage
    Then the fork appears beneath the conversation it was forked from
    But the subagent's conversation does not appear at all

  Scenario: An imported conversation is filed under the project it came from
    Given my computer is connected
    And Kiln's library holds a Claude Code conversation that ran in a project directory
    When I open the Kiln library on my phone
    Then that conversation is filed under the directory it ran in
    And it is not sitting in my Inbox

  Scenario: A conversation the desktop filed in a group appears in that group
    Given my computer is connected
    And on my Mac I filed a conversation into a group
    When I look at the library by my own grouping
    Then that conversation appears under that group
    And a group I made but have not filed anything into is still shown

  Scenario: A pinned conversation sorts ahead of a more recent unpinned one
    Given my computer is connected
    And on my Mac I pinned an older conversation
    And a different conversation was touched more recently
    When I look at the library by my own grouping
    Then the pinned conversation comes first
    And it comes first because it is pinned, not because it is newer

  Scenario: An archived conversation is kept out of the body and shown in History
    Given my computer is connected
    And Kiln's library holds an archived conversation and an active one
    When I open the Kiln library on my phone
    Then the archived conversation is not in the body of the list
    And it is shown under History

  Scenario: Filtering opens every zone, so a match is never hidden
    Given my computer is connected
    And Kiln's library holds an archived conversation and an active one
    And I have collapsed History
    When I filter for a term that only the archived conversation matches
    Then History is open anyway
    And I can see the match

  Scenario: A door with no Kiln session says it cannot reach Kiln
    Given my computer is connected
    But the door has no Kiln session at all
    When I open the Kiln library on my phone
    Then I am told Kiln could not be reached
    And I am never told that I have no conversations

  Scenario: An unreachable Kiln says it cannot reach Kiln
    Given my computer is connected
    But Kiln cannot be reached
    When I open the Kiln library on my phone
    Then I am told Kiln could not be reached
    And I am never told that I have no conversations

  Scenario: A genuinely empty library is shown as empty, and is not confused with an unreachable one
    Given my computer is connected
    And Kiln's library is genuinely empty
    When I open the Kiln library on my phone
    Then I am shown an empty library
    And that is a different state from being unable to reach Kiln

  Scenario: A conversation whose source transcript is gone says so before offering a pick-up
    Given my computer is connected
    And an imported conversation's original transcript is gone from disk
    When I open that conversation on my phone
    Then I am told its original transcript is gone
    And I am reassured nothing is lost
    And I am told when it was noticed missing

  Scenario: A conversation with no source-state makes no claim that its transcript is present
    Given my computer is connected
    And an imported conversation says nothing about whether its transcript is still on disk
    When I open that conversation on my phone
    Then nothing claims its transcript is present
    And nothing claims its transcript is gone

  Scenario: A partially imported conversation always says it was partial
    Given my computer is connected
    And a conversation was only partly imported
    When I open that conversation on my phone
    Then I am told the import was partial
    And a partial import with no stated reason still says it was partial

  Scenario: A row missing every optional field still decodes and renders
    Given my computer is connected
    And Kiln's library holds a row carrying only the fields that are always sent
    When I open the Kiln library on my phone
    Then that conversation still appears
    And the whole library did not fail to load

  Scenario: A malformed organization document leaves the library ungrouped rather than failing
    Given my computer is connected
    And my grouping document on the Mac is corrupt
    When I open the Kiln library on my phone
    Then I still see my conversations
    And they are simply ungrouped
