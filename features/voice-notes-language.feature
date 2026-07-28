Feature: The app speaks about voice notes and my knowledge base

  "Record a conversation" describes capturing OTHER PEOPLE, which is both a heavier ask
  than the product needs to make and a poor description of what most people use it for.
  The same pipeline described as "voice notes" that build "my knowledge base" is about
  authoring my own material — the ambient features then read as a bonus rather than the
  premise. This is a language change only: nothing about capture, transcription, sync or
  storage behaves differently, and internal type names are untouched.

  Scenario: the library is a knowledge base of voice notes
    Given I open the app
    Then the library speaks about voice notes
    And the library does not speak about recording conversations

  Scenario: the empty library invites me to make a note
    Given my library is empty
    Then I am invited to make my first voice note

  Scenario: the capture control is about taking a note
    Given I am in my library
    Then the control that starts capture speaks about a voice note

  Scenario: an in-progress note is described as being taken
    Given a voice note is being captured
    Then the app describes it as a voice note in progress

  Scenario: user-facing copy has retired the old language
    Given the app's user-facing copy
    Then no user-facing text calls a voice note a recording
    And no user-facing text calls my library a list of conversations

  Scenario: the change is only language
    Given I made voice notes before the language changed
    Then all of my earlier notes are still in my library
    And their transcripts are unchanged
