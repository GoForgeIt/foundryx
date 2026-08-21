Feature: The names this app already wrote to people's phones do not move

  Some identifiers in this app are not internal names at all. They are bytes sitting in
  a file or a preferences store on a phone somebody already owns — the key a setting was
  saved under, the field name inside a saved JSON document, the filename itself. This
  build did not write them. The build the person installed months ago did.

  A rename of one of those is invisible to every behavioural test in this suite, because
  those tests write and read through the same build and so agree with themselves. On the
  device, the old bytes stop being found and the setting silently reverts to its default.

  So the frontier is written down once, as a manifest of exact spellings, and this
  feature compares the manifest to what the source actually persists today. Both
  directions are failures: a spelling that moved, and a spelling that vanished.

  Scenario: every name on the frontier is still spelled the way it was shipped
    Given the manifest of identifiers already written to people's devices
    When I read the identifiers this build persists
    Then every manifest entry is present, byte-for-byte

  Scenario: nothing has appeared on the frontier without being written down
    Given the manifest of identifiers already written to people's devices
    When I read the identifiers this build persists
    Then no persisted identifier is missing from the manifest

  Scenario: the manifest's size is asserted
    Given the manifest of identifiers already written to people's devices
    When I count its entries
    Then the count equals the number declared

  Scenario: the frontier scan is not looking at an empty pile
    Given the source files that declare persisted identifiers
    When I scan them
    Then the scan found identifiers to compare
