Feature: Every conversation records which device made it, and only that device continues it

  Track 20260725T2306_device_agnostic_recording_source, task T4 — the identity-bearing
  restoration spool and archive sidecar. The other half of T4: the seam half proves a link
  drop reconnects and continues the conversation; this half proves the conversation knows
  WHICH device recorded it, so a second device cannot inherit the first one's audio and the
  archive can attribute it honestly.

  The device identity is resolved ONCE, by the composition root, and carried in. Neither
  capture-opening site is asked to discover an account scope or a device it does not
  possess: when the composition cannot resolve one it says so and capture is deferred, and
  no placeholder is ever written. A conversation recorded before this shipped has no device
  record, keeps the shipped attribution unchanged, and is reported as pre-upgrade rather
  than as a device that went missing — and one that cannot be dated at all is reported as
  undatable rather than guessed either way.

  Driven against the real `CaptureManager`, the real `OmiRestorationSpool` built through the
  real composition factory, and real capture directories on disk.

  Scenario: a conversation records the device that made it, wherever it was opened
    Given a remembered recording device is active for this account
    When the app opens a conversation
    Then the conversation records the device that made it
    When a background restoration opens a conversation through the composition factory
    Then that conversation records the device that made it too

  Scenario: a conversation recorded by the handset is not attributed to a remembered external device
    Given a remembered recording device is active for this account
    When the handset's own microphone records a conversation
    Then the conversation records the handset as its recorder
    And it is not attributed to the remembered external device
    And its device record agrees with its source marker
    When the handset records a conversation with no external device remembered at all
    Then the conversation records the handset as its recorder
    And it is not reported as a device record that went missing

  Scenario: a different device does not continue another device's conversation
    Given a conversation inside the silence gap was recorded by one device
    When a differently shaped device looks for a conversation to continue
    Then it finds nothing to continue
    When the device that recorded it looks for a conversation to continue
    Then it continues its own conversation

  Scenario: a second device reconnecting opens its own conversation instead of continuing another's
    Given device A recorded a conversation that is still inside the silence gap
    When device B's capture manager sees its stream start
    Then device B opens a new conversation rather than continuing device A's
    When device A's capture manager sees its stream start
    Then device A continues its own conversation

  Scenario: a second device's background restoration opens its own conversation instead of continuing another's
    Given device A recorded a conversation the background restoration would find
    When device B's background restoration spool sees its stream start
    Then the spool opens a new conversation rather than continuing device A's
    When device A's background restoration spool sees its stream start
    Then device A's spool continues its own conversation

  Scenario: a device record that cannot be read is its own answer, never "no record"
    Given a conversation inside the silence gap has a device record that cannot be read
    Then it is reported as having an unreadable device record
    And it is not reported as recorded before the upgrade
    And it is not reported as a device record that went missing
    When any device looks for a conversation to continue
    Then no device may continue it

  Scenario: a conversation recorded before the upgrade keeps its attribution and is not called missing
    Given a conversation inside the silence gap exists with no device record and a durable start before the upgrade
    Then it is reported as recorded before the upgrade
    And it is still attributed to the shipped recording source
    When any device looks for a conversation to continue
    Then it continues that conversation

  Scenario: a conversation that cannot be dated is never guessed to be post-upgrade
    Given a conversation exists with no device record and nothing durable to date it by
    Then it is reported as undatable
    And it is not reported as a device record that went missing

  Scenario: a blocked account scope defers capture instead of writing a placeholder
    Given the account scope cannot be resolved for a background restoration
    Then the composition refuses to resolve a device context
    And the spool opens no conversation while the device is streaming
    And no device record is written anywhere
