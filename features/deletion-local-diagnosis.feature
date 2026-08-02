Feature: A blocked deletion says what blocked it
  The local erase gate is strict on purpose — it refuses unless the current
  Keychain identity exactly owns the data about to be destroyed. But several
  distinct refusals all became one `cleanupPending`, and the person saw a single
  "Deletion is pending. This account stays closed until cleanup finishes."

  On 2026-08-02 that cost a round trip. The REMOTE teardown had succeeded — cell
  destroyed, tenant purged, confirmed in the server audit — while the local erase
  refused, and nothing on the device said which refusal it was. A gate that can
  say no must be able to say why.

  These scenarios pin BOTH halves of each attempt: what the command wrote down,
  and what it did NOT destroy. A refusal that quietly erased something would pass
  a records-only check.

  # A deletion is a COMMAND. Asserting only that a later read looks right lets a
  # command that never ran, or ran too far, go unnoticed — so every scenario here
  # asserts the write it emitted AND the data it left alone.
  Scenario: An erase for an identity that does not own the data refuses and says so
    When an erase is attempted for an identity that does not own the data
    Then the refusal is recorded with its cause
    And nothing belonging to the other account was erased

  Scenario: An erase with no proven identity refuses before touching anything
    When an erase is attempted with no proven identity
    Then the refusal is recorded with its cause
    And the data container was never opened

  Scenario: The recorded cause survives the erase it describes
    When an erase is attempted for an identity that does not own the data
    Then the record is held somewhere the erase cannot remove
