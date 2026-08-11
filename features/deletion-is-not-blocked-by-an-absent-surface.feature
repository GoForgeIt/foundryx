Feature: A surface that is not there does not block deleting my account
  Before erasing anything, deletion asks every account-bound part of the app to
  close and waits for each one to acknowledge. That barrier is the reason a
  deleted account cannot keep rendering on a widget or a Live Activity, so a
  part that CANNOT PROVE it closed must keep the account closed.

  But a part that reports "there is nothing here" is not a part that failed. A
  Live Activity the person never configured, or a screen already released, has
  no surface to leak — and on TestFlight 771837 that answer was counted as a
  hard failure. "Delete everything now" refused with "deletion is incomplete at
  preparing: exposureBarrierFailed", and retrying re-ran the identical barrier,
  so the account was locked shut on the device with no way out.

  # The two absences. Neither can leak anything, so neither may block.
  Scenario: A part of the app that was already released does not block my deletion
    Given a part of the app that must close on deletion has already been released
    When I delete everything now
    Then my deletion finishes
    And every erase step runs

  Scenario: A part of the app I never set up does not block my deletion
    Given a part of the app that must close on deletion was never attached to any account
    When I delete everything now
    Then my deletion finishes
    And every erase step runs

  # The refusals. These must stay red-able: this is the whole reason the barrier
  # exists, and "stop blocking deletion" must never become "ignore every error".
  Scenario: A part that cannot confirm it closed still blocks my deletion
    Given a part of the app cannot confirm that it closed
    When I delete everything now
    Then my deletion does not finish
    And no erase step runs
    And my account stays closed until every erase step finishes

  Scenario: A part whose close was not saved still blocks my deletion
    Given a part of the app could not durably record that it closed
    When I delete everything now
    Then my deletion does not finish
    And no erase step runs

  # An older copy of the SAME account is the one case where refusing was worse
  # than useless: it neither closed the surface nor let the erase run. Signing in
  # remounts the screens and bumps the account's generation, so an older copy is
  # left registered on an ordinary launch — and it answered "you are not who I am
  # bound to" forever. It must be ASKED to close, because it is the same account.
  Scenario: A part still bound to an older version of my account is asked to close
    Given a part of the app is still bound to an earlier version of my account
    When I delete everything now
    Then that part was asked to close
    And my deletion finishes
    And every erase step runs

  Scenario: A second copy of a part left over from signing in does not block my deletion
    Given a second copy of the same part of the app is still registered from before I signed in
    When I delete everything now
    Then my deletion finishes
    And every erase step runs

  # Asking it is not the same as excusing it. A stale copy that cannot confirm it
  # closed is still an open surface of this account.
  Scenario: An older copy that cannot confirm it closed still blocks my deletion
    Given a part of the app is still bound to an earlier version of my account and cannot confirm that it closed
    When I delete everything now
    Then my deletion does not finish
    And no erase step runs

  # Someone else's account is not this account. Refusing here was the same
  # lockout: switching accounts leaves the previous account's screens registered.
  Scenario: A part belonging to a different account does not block my deletion
    Given a part of the app is bound to a different account
    When I delete everything now
    Then that part was not asked to close
    And my deletion finishes
    And every erase step runs

  # Accepting absence must not become a way to LAUNDER a refusal. A part of the
  # app made of several pieces answers for all of them, and if it may answer
  # "nothing here" as soon as its first piece is missing, a second piece that
  # could not confirm it closed disappears — and the erase runs anyway.
  Scenario: An absent piece does not cover for a piece that cannot confirm it closed
    Given a part of the app has one piece that is gone and one that cannot confirm it closed
    When that part answers for all of its pieces
    Then it reports that it cannot confirm it closed

  Scenario: A part whose pieces are all absent reports that nothing is there
    Given a part of the app has only pieces that are gone
    When that part answers for all of its pieces
    Then it reports that there is nothing there

  # The same rule two steps later. The barrier is checked twice — once when the
  # parts answer and once when the answers are verified — and a rule that only
  # got fixed in one place is the same lockout under a different step name.
  Scenario: An absent part is accepted by the barrier verification too
    Given a part of the app that must close on deletion was never attached to any account
    When the deletion barrier verifies what every part answered
    Then the barrier is satisfied

  Scenario: A part that cannot confirm it closed fails the barrier verification
    Given a part of the app cannot confirm that it closed
    When the deletion barrier verifies what every part answered
    Then the barrier is not satisfied
