Feature: Activity shows what FoundryX has done for me

  One place answering "what has it done for me?": a newest-first ledger of ambient
  nudges (shown, accepted, dismissed), answers from my own memory with my rating,
  and agent runs — each linking back to where it came from. Days with activity get
  a daily recap; a week with activity gets a weekly recap. Empty days and weeks
  stay silent — no card, no filler. Personal measures are plain sentences, never
  charts or internal tool names. Everything shown is read from what actually
  happened; a missing or half-written record is skipped honestly, never invented.

  Scenario: the ledger lists what happened, newest first
    Given a nudge was shown during yesterday's conversation
    And I dismissed a nudge this morning
    And I accepted a nudge this afternoon
    When I open Activity
    Then I see the accepted nudge first
    And the dismissed nudge below it
    And yesterday's nudge last

  Scenario: each entry links to its source
    Given a nudge came from a recorded conversation
    And an accepted nudge opened a chat
    When I open Activity
    Then the nudge links to that conversation
    And the accepted nudge links to that chat

  Scenario: an answer shows my own rating
    Given an answer was compiled from my memory
    And I rated it helpful
    When I open Activity
    Then I see the answer with my rating alongside

  Scenario: routine internal decisions stay invisible
    Given the assistant quietly considered many moments and decided to stay silent
    When I open Activity
    Then none of those silent decisions appear in the ledger

  Scenario: a day with activity gets a daily recap
    Given yesterday had a nudge I accepted
    When I open Activity
    Then yesterday shows a recap card summarizing the day

  Scenario: an empty day stays silent
    Given a day had no activity
    When I open Activity
    Then that day shows no recap card and no filler

  Scenario: the week rolls up only when there is something to say
    Given this week had activity
    And last week had none
    When I open Activity
    Then this week shows a weekly recap
    And last week shows nothing

  Scenario: recaps come from my own activity
    Given a day with a nudge and an answer
    When the recap is written
    Then it reflects only what actually happened that day

  Scenario: measures are plain sentences
    Given a week with one nudge I accepted and one answer I rated helpful
    When I open Activity
    Then the measures read as plain sentences like "1 nudge · you accepted it"
    And no internal tool names appear anywhere

  Scenario: a missed notification is still visible
    Given a nudge was shown while my phone was silenced
    When I open Activity
    Then I can still see that nudge among recent notifications

  Scenario: a half-written record never breaks the page
    Given the activity records contain an unreadable or partial entry
    When I open Activity
    Then the readable entries still appear
    And nothing crashes or shows made-up details

  Scenario: no activity at all is an honest empty page
    Given nothing has happened yet
    When I open Activity
    Then I see a quiet explanation that activity will appear here
    And no recap cards and no measures
