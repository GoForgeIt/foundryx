Feature: a recording says what is happening to it, and never invents a number

  Nick tapped Bring over on 2026-08-14. The recording came off the recorder, the
  segments were acknowledged by his cell, the cell transcribed it, and the phone
  told him none of that. He asked, in his words:

    "it would be good to be able to see status of loading to cell as well as how
     long it will be until it's transcribed? or if any ambient intelligence came
     from it? ... progress for transcribing would be nice and progress towards
     summary would be nice as well"

  So this recording now carries a JOURNEY: what came off the recorder, what is
  durable on this phone, what reached the place this account actually saves to,
  whether a transcript exists, whether a summary exists, and whether anything was
  surfaced from it.

  AND THE NUMBERS ARE GOVERNED. This surface has printed an invented figure three
  times: 44-minute rows from an unmeasured divisor, kilobytes rendered as bytes,
  and a "4 KB" label on a 19,770-byte file. A bar and a percentage are claims that
  a denominator exists AND is settled. A recording still being written to has a
  denominator that grows, so it gets a COUNT — never a percentage, never a bar.
  Transcription and summarizing have no denominator at all, so they get a LABEL.

  Scenario: bytes coming off the recorder are a real fraction of what it announced
    Given a recorder announced 1,000,000 bytes and 250,000 have arrived
    Then the journey shows how far the transfer has got
    And that step shows a bar
    And that step's line names both numbers

  Scenario: a transfer whose total the recorder never announced shows a count only
    Given a transfer with 250,000 bytes arrived and no announced total
    Then that step shows no bar
    And that step's line carries no percentage

  Scenario: segments still being written are counted, not divided
    Given a recording that is still being written to, with 12 of 40 segments acknowledged
    Then the step for the place this account saves to shows no bar
    And that step's line carries no percentage

  Scenario: segments that stopped growing are a real fraction
    Given a finished recording with 40 of 40 segments acknowledged
    Then the step for the place this account saves to shows a bar
    And that step's line names both numbers

  Scenario: a recorder that sent more than it announced is not rendered as over-complete
    Given a recorder announced 1,000 bytes and 4,000 have arrived
    Then that step shows no bar
    And that step's line carries no percentage

  Scenario: a recording that has already come over is not still coming over
    Given a recording whose file is already on this phone, with no transfer ever measured
    Then the step for coming off the recorder is marked done
    And that step's line names no number

  Scenario: a recording this phone made itself has no transfer step
    Given a recording this phone made with its own microphone
    Then the journey has no step for coming off a recorder

  Scenario: no step in any journey ever shows a percentage it cannot divide
    Given every journey this app can build
    Then a step shows a percentage only when it holds a settled denominator
    And a step shows a bar only when it holds a settled denominator

  Scenario: transcribing is a label, never a bar
    Given a recording that has reached the place it is saved and is being transcribed
    Then the transcript step is marked as working
    And the transcript step shows no bar
    And the transcript step's line carries no percentage

  Scenario: summarizing is a label, never a bar
    Given a recording whose transcript exists and whose summary is being written
    Then the summary step is marked as working
    And the summary step shows no bar

  Scenario: the phone-only tier is never told about a second place
    Given a recording on the phone-only tier
    Then the journey has no step for a second place
    And no step names a computer
    And no step names a Vault

  Scenario: a recording saved to a Vault says Vault, not computer
    Given a recording saved to a Vault
    Then the journey has a step for a second place
    And that step names the Vault
    And no step names a computer

  Scenario: speakers are named only when speakers were actually returned
    Given a transcribed recording whose reply carried 3 separated speakers
    Then the transcript step says how many speakers were separated

  Scenario: an empty speaker list is not reported as "one speaker"
    Given a transcribed recording whose reply carried no separated speakers
    Then no step says anything about speakers

  Scenario: a recording nothing has read yet says so
    Given a recording with no transcript yet
    Then the surfaced step says nothing has been read yet
    And the surfaced step is not marked done

  Scenario: a recording that was read and had nothing in it says that
    Given a transcribed recording the gate read and found nothing in
    Then the surfaced step says it was read and nothing was found
    And the surfaced step is marked done

  Scenario: a recording the gate could not read is not reported as empty
    Given a transcribed recording the gate could not read
    Then the surfaced step says it could not be read
    And the surfaced step does not say nothing was found

  Scenario: a recording something came out of counts what came out
    Given a transcribed recording that surfaced 2 items
    Then the surfaced step is marked done
    And the surfaced step counts 2 items

  Scenario: the five ways a reading can end never share a sentence
    Given every way the surfaced step can end
    Then no two of them read the same
    And only the ones where more may still happen say "yet"
