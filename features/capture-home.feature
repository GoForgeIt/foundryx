Feature: Finding and organizing conversations on the capture home

  The capture page is the daily surface: every conversation is findable by
  search, organizable into categories the user controls, and readable at a
  glance. Search only searches what is on the phone (titles and locally cached
  transcripts) — it never pretends to reach further. Categories ship with
  sensible defaults, the model may suggest one, and the user's own choice
  always wins and is remembered.

  Cards are content-first: a conversation reads as its title, its summary, a
  quiet time-and-place line, and one human status word. Engineering telemetry
  (segment counts, byte totals, raw transport errors) never reaches a card —
  a sync problem is simply "Waiting for computer"; details stay in the logs.

  Scenario: a conversation card shows its title and summary, never sync internals
    Given a conversation titled "Launch deck and relay numbers" with a summary, still syncing after a transport error
    When its card is presented
    Then the card shows the title and the summary
    And the card shows a human meta line with its date, time, and duration
    And the card never shows segment counts, byte sizes, or raw errors

  Scenario: a syncing conversation reads Waiting for computer
    Given a conversation with segments still waiting to reach the computer
    When its card is presented
    Then its status word is "Waiting for computer"
    And a sync error changes nothing the user sees

  Scenario: a card's title falls back to the first words spoken, never a filename
    Given a conversation with no title yet whose transcript begins "we should move the launch to Friday because"
    When its card is presented
    Then the card's title begins with the first words spoken
    And the card's title is never the capture's internal identifier

  Scenario: the record CTA describes where audio is saved
    Given the capture home on a phone-only install
    Then a "Record a conversation" card reads "Saved on this phone. It joins your full history when your computer connects."
    And on the computer tier the card reads "Saved on this phone. It joins your full history on your computer."
    And on the cell tier the card reads "Saved on this phone. It joins your full history in your Vault."

  Scenario: Search all opens conversation search
    Given the capture home lists recent conversations under "Recent on this phone"
    When I tap "Search all"
    Then the conversation search field opens
    And closing search clears the query

  Scenario: the recording caption reads a human state, not diagnostics
    Given a recording is in progress
    Then the meter caption reads "Recording"
    And when paused it reads "Paused, not listening"
    And it never shows frame counts or byte sizes

  Scenario: searching narrows the list by title
    Given I have conversations titled "Standup" and "Dinner plans"
    When I search for "stand"
    Then only "Standup" remains in the list

  Scenario: searching also looks inside transcripts on my phone
    Given a conversation whose cached transcript mentions "budget review"
    When I search for "budget"
    Then that conversation remains in the list

  Scenario: default categories are ready on first run
    Given a fresh install
    Then the categories are "Work", "Personal", and "Ideas"

  Scenario: I can create my own category
    Given the default categories
    When I create a category named "Clients"
    Then "Clients" appears among my categories

  Scenario: deleting a category never deletes conversations
    Given a conversation filed under "Ideas"
    When I delete the category "Ideas"
    Then the conversation still exists
    And it is no longer filed under any category

  Scenario: the model may suggest a category but my choice wins
    Given a conversation the model filed under "Work"
    When I move it to "Personal"
    Then it stays under "Personal"
    And a later model suggestion does not move it

  Scenario: filtering by category shows only that category
    Given conversations filed under "Work" and "Personal"
    When I filter by "Work"
    Then only the "Work" conversations remain
