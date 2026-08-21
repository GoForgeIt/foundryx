Feature: An upgraded phone keeps the brain it already chose

  A person picked "My computer" as their brain months ago. That choice lives on their
  phone as three bytes on disk. When they install a new version of the app, the app must
  read those same bytes back and put them in the same place they left it.

  This is the invariant a rename breaks silently. Nothing crashes, no test about
  behaviour goes red, and the app simply forgets — every installed device quietly falls
  back to "Just my phone" and starts capturing to a different brain than the one the
  person chose. The spellings on disk are therefore frozen, and this feature is what
  makes changing one of them fail out loud.

  Scenario: an upgraded device keeps its brain selection
    Given a phone that already chose "My computer" on an older version of the app
    When the upgraded app reads the brain selection
    Then the phone is still on "My computer"

  Scenario: an upgraded device that chose the phone keeps the phone
    Given a phone that already chose "Just my phone" on an older version of the app
    When the upgraded app reads the brain selection
    Then the phone is still on "Just my phone"

  Scenario: the spellings already written to every installed phone are frozen
    Given the brain selections a shipped app has already written to disk
    When I compare them to the spellings this version writes
    Then every spelling is byte-identical
    And the number of frozen spellings is asserted

  Scenario: the place the selection is stored is frozen too
    Given the storage key a shipped app has already written to
    When I compare it to the key this version reads
    Then the key is byte-identical
