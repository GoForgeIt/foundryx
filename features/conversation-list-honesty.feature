Feature: The conversation list tells the truth and stays fast

  Root causes from the 2026-07-07 deep review (workflow wf_f48ab1cc-488, all
  adversarially confirmed): stale empty cards survived a whole app session because
  the launch prune never republished the visible list; dead cards read "Recording"
  because an empty WAL always reports the recording stage; the list stuttered
  because a 12 Hz audio-meter tick re-rendered every row with per-row disk reads;
  and completed conversations polled the desktop every 5 seconds forever.

  Scenario: stale empty recordings vanish at launch, not at next relaunch
    Given yesterday's capture opened but never received any audio
    When I launch the app
    Then that conversation does not appear in my list
    And it does not appear later in this same session either

  Scenario: an ended conversation never claims to be recording
    Given a conversation that ended and has no audio segments on the phone
    When I look at its card in the list
    Then its status does not say "Recording"
    And it shows no live green recording indicator

  Scenario: only the live conversation shows a recording indicator
    Given I am actively recording a conversation right now
    And older conversations exist in my list
    When I look at the list
    Then only the active conversation shows the recording indicator

  Scenario: a completed conversation stops asking the computer about itself
    Given a conversation whose transcript is already saved on my phone
    When I look at my conversation list
    Then the app does not keep asking the computer for that conversation's status

  Scenario: the sync banner only counts work that will actually happen
    Given some old conversations were discarded as empty
    And a real conversation still has segments waiting to upload
    When I read the sync banner
    Then the pending count includes only the real conversation's segments
    And the banner says syncing only while uploads are actually running

  Scenario: the banner surfaces how many conversations are processing
    Given two conversations are still being transcribed
    And a third conversation's transcript is ready
    When I look at the top of the list
    Then the banner says two conversations are processing
    And it does not count the ready conversation
