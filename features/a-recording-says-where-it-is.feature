Feature: A recording says where it is, and is named before it is understood

  Nick tapped Bring over, a Pocket recording came off the device, reached his Vault
  and was transcribed there — and his phone still said "Transcribing locally". The
  capture page DOES show Pocket recordings; the screenshot has the row, the device
  chip and the three faces. What it could not say was WHERE the recording was.

  He asked for five things: progress pulling off the device, status reaching the
  cell, progress towards transcription, progress towards summary, and whether any
  ambient intelligence came out of it. And then: a name, fast, from the first part
  of the transcript, replaced by the real one later.

  THE RULE THIS FEATURE IS MOSTLY ABOUT. This surface has printed an invented
  number three times — 44-minute rows from an unmeasured divisor, kilobytes stored
  and read back as bytes, and a "4 KB" label on a 19,770-byte file. So a share of a
  total may be drawn ONLY where somebody measured the total. Everywhere else it is
  a count, or a sentence, and never a bar. Half the scenarios below assert an
  absence for that reason.

  Scenario: A recording being transcribed says how far along it is
    Given a recording whose Vault transcribes it in twenty parts
    And two of those parts are done
    Then it says it is being transcribed
    And it says two of twenty parts are done
    And a progress bar may be drawn for it

  Scenario: A recording being transcribed in no countable parts shows no bar
    Given a recording that is being transcribed with no countable parts
    Then it says it is being transcribed
    And no progress bar may be drawn for it

  Scenario: A recording whose speakers cannot be separated says so, and shows no bar
    Given a recording on a Vault that cannot separate speakers
    Then it says the speakers were not separated
    And no progress bar may be drawn for it
    And it does not say the speakers are being separated

  Scenario: A recording nobody has said anything about does not invent a stage
    Given a recording nothing is known about
    Then it says nothing about separating speakers
    And it says nothing about actions

  Scenario: A recording still coming off the recorder says so
    Given a recording that has 40000 of its announced 100000 bytes off the recorder
    Then it says it is coming off the recorder
    And a progress bar may be drawn for it

  Scenario: A recording coming off a recorder that announced nothing shows a count and no bar
    Given a recording that has 40000 bytes off the recorder and no announced total
    Then it says it is coming off the recorder
    And no progress bar may be drawn for it

  Scenario: Segments reaching the Vault with no known total are a count, not a share
    Given 79 segments have reached the Vault and nobody knows how many there are
    Then no progress bar may be drawn for reaching the Vault

  Scenario: Segments reaching the Vault with a known total are a share
    Given 79 of an expected 100 segments have reached the Vault
    Then a progress bar may be drawn for reaching the Vault
    And the share drawn is 79 of 100

  Scenario: A recording that produced no actions says so, and a recording that was never read says something different
    Given a recording that has been read for actions and produced none
    Then the actions stage reads "ranFoundNothing"
    Given a recording that has never been read for actions
    Then the actions stage reads "neverRun"

  Scenario: A recording with a transcript and no name does not claim work is in flight
    Given a recording that has been transcribed and has no name
    Then it says nothing about naming it

  Scenario: A long recording is named from its first few minutes
    Given a recording named from its first few minutes
    Then it has that name
    And it says the name came from the first few minutes

  Scenario: The full name replaces the provisional one
    Given a recording named from its first few minutes
    When the whole recording has been understood
    Then it carries the full name
    And it no longer says the name is provisional

  Scenario: A provisional name never replaces a real one
    Given a recording that already carries its full name
    When a provisional name arrives late
    Then it still carries the full name

  Scenario: A name already shown is never blanked by a reply that carries none
    Given a recording named from its first few minutes
    When a reply arrives carrying no name at all
    Then it still has a name
