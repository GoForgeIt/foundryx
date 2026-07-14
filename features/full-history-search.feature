Feature: Search reaches my whole history when my computer is connected
  The Capture search icon searches what's on the phone. When my computer is connected it
  ALSO reaches my full library in Lore, so I can find any past conversation — not just the
  recent ones the phone keeps locally.

  Scenario: Connected — computer results join local results, deduped
    Given I have local conversations on my phone
    And my computer is connected
    When I search a term that also matches older conversations on my computer
    Then I see my local matches
    And I see the computer matches that aren't already local
    And a conversation that is both local and on the computer appears only once

  Scenario: Tapping a computer-only result opens it
    Given my computer is connected
    And a matching conversation lives only on my computer
    When I tap that result
    Then it opens the conversation detail, fetched from my computer by its id

  Scenario: Not connected — local only, honestly said
    Given my computer is not connected
    When I search
    Then I only see local matches
    And I am told to connect my computer to search my full history

  Scenario: Connected but unreachable — honest failure
    Given my computer is connected
    But the computer can't be reached
    When I search
    Then I am told the computer couldn't be reached

  Scenario: Empty query searches nothing remote
    Given my computer is connected
    When I clear the search field
    Then no computer search runs
