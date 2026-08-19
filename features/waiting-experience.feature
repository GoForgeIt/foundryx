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

  Scenario: transcription is named as on this iPhone and private
    Given a conversation is being transcribed on my iPhone
    When I look at the waiting experience
    Then it says it is transcribing on this iPhone
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

  # The cell tier (rung 3): the Vault is a THIRD brain, not a Mac. A Vault owner's audio
  # goes to their own Vault — a private machine run on their behalf — so the waits must
  # say that, and must never claim a Mac, a relay, or "the audio never goes to a server"
  # on a tier where every one of those claims is false.

  Scenario: transcription in the Vault is named honestly
    Given a conversation is being transcribed in my Vault
    When I look at the waiting experience
    Then it says it is transcribing in my Vault
    And it tells me my Vault is a private machine of my own
    And it does not claim the audio stays on a device in my hands
    And it does not mention a Mac or a computer
    And it does not show a progress bar

  Scenario: fetching from the Vault does not invent a relay
    Given content is being fetched from my Vault
    When I look at the waiting experience
    Then it says it is fetching from my Vault
    And it does not mention a relay
    And it does not mention a Mac or a computer

  Scenario: syncing a backlog to the Vault counts segments into the Vault
    Given 214 of 1210 segments have synced to my Vault
    When I look at the waiting experience
    Then it shows a real progress bar
    And it says "214 of 1,210 segments safely in your Vault"

  Scenario: titling in the Vault names the Vault's model
    Given a conversation is being titled in my Vault
    When I look at the waiting experience
    Then it tells me a model in my Vault is naming it
    And it does not mention a Mac or a computer

  Scenario: every wait names only a place its owner has
    Given every destination a voice note can land in
    When I read every sentence each wait can show
    Then no destination's words name a place its owner does not have
    And no two destinations share the words for a wait whose place differs by tier
    And only the computer tier ever mentions the relay
    And only the phone tier claims the audio never leaves the device

  # The capture-screen sync strip (WS-B): a calm, one-line, constant-height row. It must
  # never jerk the conversation list, never flicker on brief syncs, and never blink out
  # the instant a drain finishes.

  Scenario: a brief sync never flashes the syncing bar
    Given my library shows some conversations
    When a sync starts and finishes within a second
    Then the syncing bar is never shown

  Scenario: a sustained sync shows the bar after a moment without moving the list
    Given my library shows some conversations
    When a sync stays active for more than two seconds
    Then the syncing bar is shown
    And the conversation list below the strip never moves

  Scenario: once shown, the syncing bar never disappears in under three seconds
    Given my library shows some conversations
    And a sync has been active long enough to show the syncing bar
    When the sync finishes right away
    Then the syncing bar is still shown two seconds later
    And it has settled by four seconds later

  Scenario: when everything is synced the strip settles to all conversations saved
    Given my library shows some conversations
    And a sync has run and then finished and settled
    When I read the strip
    Then it says all my conversations are saved
