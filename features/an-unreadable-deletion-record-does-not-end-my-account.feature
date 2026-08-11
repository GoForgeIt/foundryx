Feature: A deletion record this build cannot read does not end my account
  An unfinished deletion is remembered in a small file, and that file is read by
  a decoder sealed on an exact set of fields and an exact version. Add one field
  in a new build, or install an older build after a newer one — completely
  ordinary on TestFlight — and the record will not parse.

  That was terminal in three places at once. The app resolved to no account root
  and was unusable. "Delete everything" answered "incomplete at preparing:
  store_blocked corrupt", and the retry read the same bytes and said the same
  thing. Signing in was refused with "account deletion state is unreadable".
  Deleting and reinstalling the app was the only way out.

  Nothing in that file is irreplaceable: it holds a counter and a list of erase
  steps already done, every erase step is safe to run again, and each one is
  independently re-checked before the deletion is called finished. So bytes we
  cannot parse mean "start the erase over", not "this account ends here".

  Scenario: A record this build cannot parse is rebuilt and the erase finishes
    Given the record of my unfinished deletion cannot be parsed
    When I finish the interrupted deletion
    Then the deletion finishes
    And every erase step runs

  Scenario: A record written by a newer build is rebuilt and the erase finishes
    Given the record of my unfinished deletion was written by a newer build
    When I finish the interrupted deletion
    Then the deletion finishes
    And every erase step runs

  # The rebuilt record must not reuse a counter the old one may still be
  # remembered by, anywhere else on the device.
  Scenario: The rebuilt record counts past the one that could not be read
    Given the record of my unfinished deletion cannot be parsed but still names its count
    When I finish the interrupted deletion
    Then the deletion finishes
    And the rebuilt record counts higher than the one that could not be read

  # "Cannot parse" is not "cannot open". If the file could not be opened at all,
  # a real record may be sitting there intact, and overwriting it would throw
  # away erase steps that really did finish.
  Scenario: A record that cannot be opened at all is not overwritten
    Given the record of my unfinished deletion cannot be opened at all
    When I finish the interrupted deletion
    Then the deletion does not finish
    And the record on disk is left exactly as it was
