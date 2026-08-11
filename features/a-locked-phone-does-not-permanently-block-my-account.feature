Feature: A launch on a locked phone does not permanently block my account
  iOS relaunches this app in the background on its own — for a Bluetooth
  recorder, among other things — and it can do that while the phone is still
  locked, before the first unlock of the day. Files this app protects cannot be
  opened then. So the first question the app asks about the account, "is there an
  unfinished deletion here?", comes back "I could not read that".

  Refusing was right. REMEMBERING the refusal was not: the answer was cached for
  the life of the process, and unlocking the phone and opening the app changed
  nothing. No account root, deletion refused because it could not prove who owns
  the data, sign-in refused. Force-quitting was the only way out and nothing on
  screen said so.

  An answer that means "I could not read it" is a fact about the lock, not about
  the account, so it must never be remembered.

  Scenario: Unlocking the phone gives me my account back
    Given the app started while the phone was locked and could not read the deletion record
    Then I have no account root
    When the phone is unlocked
    Then I have my account root back without restarting the app

  # The other half. An answer that IS about the account is still remembered, so
  # this does not turn into re-reading the disk for every question the app asks.
  Scenario: A decided answer is still remembered
    Given the app started with the phone unlocked and a readable deletion record
    When the app asks for the account root twice
    Then it only read from disk once
