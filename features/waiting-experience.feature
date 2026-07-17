Feature: An honest waiting experience for every slow moment

  Some things the app does are irreducibly slow: an on-device model writing a recap or
  a title, on-device transcription, fetching a conversation from the user's Mac, or
  draining a big backlog of audio segments up to the computer. Rather than a bare
  spinner or a fake progress bar, every wait longer than about a second uses ONE shared
  experience: it names what's happening in plain, honest language; it shows a REAL
  progress bar only when there are true counts to show (sync); and it rotates a small
  set of genuinely-true facts about what the app is doing locally with the user's data.
  Nothing here is ever a lie — no invented percentage, no fake progress.

  Scenario: a recap being generated on-device is named honestly
    Given a recap is being generated on my iPhone
    When I look at the waiting experience
    Then it says it is summarizing on my iPhone
    And it tells me the recap is written entirely on my device
    And it does not show a progress bar

  Scenario: a recap wait shows a true fact about local processing
    Given a recap is being generated on my iPhone
    When I look at the rotating fact
    Then the fact is one of the true things the app does locally

  Scenario: syncing a backlog shows real, honest progress
    Given 214 of 1210 segments have synced to my computer
    When I look at the waiting experience
    Then it shows a real progress bar
    And it says "214 of 1,210 segments safely on your computer"

  Scenario: transcription is named as local and private
    Given a conversation is being transcribed on my iPhone
    When I look at the waiting experience
    Then it says it is transcribing locally
    And it tells me the audio never leaves my phone
    And it does not show a progress bar

  Scenario: a long transcription admits it is taking longer
    Given a conversation is being transcribed on my iPhone
    When it has been transcribing for 25 seconds
    Then it tells me longer recordings take longer

  Scenario: fetching from the Mac names the encrypted tunnel
    Given content is being fetched from my Mac
    When I look at the waiting experience
    Then it says it is fetching from my Mac
    And it tells me the tunnel is end-to-end encrypted
    And it does not show a progress bar

  Scenario: titling a conversation is named honestly
    Given a conversation is being titled on my iPhone
    When I look at the waiting experience
    Then it says it is naming this conversation
    And it does not show a progress bar

  Scenario: the rotating fact changes over time but is stable at each moment
    Given a recap is being generated on my iPhone
    When I look at the rotating fact after 0 seconds and again after 5 seconds
    Then the two facts are different
    And looking again at the same moment shows the same fact
