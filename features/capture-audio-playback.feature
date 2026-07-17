Feature: Hearing a conversation's audio, honestly

  Some conversations you don't remember — an ambient capture that triggered on a clap of
  thunder, a meeting you half-caught. The only way to know what a capture is, is to HEAR
  it. The detail view offers "Listen": it plays the capture's own audio, fetched from
  your computer where the recording lives (the phone never keeps a copy). While it fetches
  it says so; while it plays you can stop it.

  Playback is honest about what can go wrong. Recordings live on your computer and aren't
  kept there forever, so an old capture whose audio was pruned reads "Audio no longer
  available" — a plain fact, not a raw error. When the computer itself can't be reached
  (asleep, off the network) the line is different and just as plain: the audio lives on a
  computer we can't reach right now.

  And playback never fights the microphone: while a recording is in progress, Listen and
  "Hear this voice" are off, with a line that says why — the app will not steal the audio
  route out from under a live recording.

  Listen plays the WHOLE conversation, start to finish — not a snippet. While it plays,
  the row is a real transport: a scrubber you can drag to any point and an "elapsed / total"
  readout, so you always know how far into the conversation you are.

  Scenario: listening to an ambient capture you don't remember
    Given a recorded conversation whose audio is available on the computer
    When I tap "Listen"
    Then the audio loads and then plays

  Scenario: playing the whole conversation shows how far in you are
    Given playback is 12 seconds into a 245 second recording
    Then the elapsed readout reads "0:12 / 4:05"
    And the scrubber is filled to that position

  Scenario: the elapsed readout never runs past the end
    Given playback is 400 seconds into a 245 second recording
    Then the elapsed readout reads "4:05 / 4:05"
    And the scrubber is filled to the end

  Scenario: the recording's audio was pruned from the computer
    Given a recorded conversation whose audio has been pruned from the computer
    When I tap "Listen"
    Then I see "Audio no longer available"
    And I do not see any raw error text

  Scenario: the computer can't be reached
    Given the computer that holds the audio can't be reached
    When I tap "Listen"
    Then I see that the computer can't be reached
    And the unreachable message is distinct from the pruned-audio message

  Scenario: playback is off while I'm recording
    Given a recording is in progress
    When I look at a conversation's Listen row
    Then playback is disabled with the reason "Playback is off while you're recording"

  Scenario: the voice-sample row is also off while I'm recording
    Given a recording is in progress
    When I look at a speaker's "Hear this voice" row
    Then playback is disabled with the reason "Playback is off while you're recording"

  Scenario: playback returns after I stop recording
    Given no recording is in progress
    When I look at a conversation's Listen row
    Then playback is allowed
