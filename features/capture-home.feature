Feature: Finding and organizing conversations on the capture home

  The capture page is the daily surface: every conversation is findable by
  search, organizable into categories the user controls, and readable at a
  glance. Search only searches what is on the phone (titles and locally cached
  transcripts) — it never pretends to reach further. Categories ship with
  sensible defaults, the model may suggest one, and the user's own choice
  always wins and is remembered.

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
