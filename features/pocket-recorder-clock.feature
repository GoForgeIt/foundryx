Feature: A brought-over recording's time is trusted, or its warning means something
  A recorder stamps its own recordings. Until now every recording that came off one was labelled
  "the clock may have drifted" — including the ones whose time was perfectly good — because the
  app treated "we have never set this recorder's clock" as if it were evidence that the clock was
  wrong. A warning that appears on everything is read as nothing, and this one was read by
  nothing: it was never put in front of the person who brought the recording over.

  The recorder has no way to be asked what time it thinks it is. The one thing it can say about
  its own clock is a recording stamped later than the moment this phone received it, which is a
  time no recording can honestly have. That is the only proof there is, so that is the only thing
  the warning is allowed to fire on — and when it does fire, the person sees it.

  Scenario: a recording the recorder dates sensibly is trusted in silence
    Given a recording the recorder dates before the moment it was brought over
    When it is brought over
    Then it keeps the recorder's own time and carries no clock warning

  Scenario: a recording the recorder could not have made yet is called out
    Given a recording the recorder dates after the moment it was brought over
    When it is brought over
    Then it is filed under the day it arrived, the recorder's reported time is kept, and the warning says the recorder is ahead

  Scenario: the warning reaches the person who asked for the recording
    Given a brought-over recording whose recorder time is impossible
    When the result of that bring-over is put into words
    Then the words say the recording landed and then say the recorder's clock is ahead

  Scenario: a recording with no clock trouble adds nothing to what the person reads
    Given a brought-over recording whose recorder time is ordinary
    When the result of that bring-over is put into words
    Then the words are exactly the ordinary landing sentence and nothing more

  Scenario: a whole shelf is not warned about wholesale
    Given a shelf of recordings the recorder dates across several days before they were fetched
    When every one of them is brought over
    Then not one of them carries a clock warning

  Scenario: the clock warning is written by the clock rule and read by what a person sees
    Given the shipped source of the app and of its kit
    When the clock warning is traced from where it is written to where it is read
    Then it has at least one writer and at least one reader, and nothing is left that only a deleted trust point could have produced
