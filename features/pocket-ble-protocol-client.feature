Feature: Pull completed recordings through a bounded BLE protocol session
  Pocket protocol behavior is verified against provenance-labelled fake traces without hardware.

  Scenario: Authenticate on the complete primary characteristic map
    Given a connected fake transport with the complete primary map
    When I authenticate with a valid synthetic session secret using a proposal live capture
    Then authentication succeeds and a subsequent information command is permitted

  Scenario: Select only a complete supported characteristic map
    Given connected fake transports with a complete fallback map and a partial map
    When I probe and authenticate both transports
    Then the reference-derived fallback succeeds and the partial map is unsupported

  Scenario: Unknown commands are unsupported on every map
    Given an authenticated fake transport that returns the proposal live unknown-command capture
    When I request device information
    Then the operation fails as unsupported rather than succeeding with empty data

  Scenario: Authentication failures fail closed
    Given connected fake transports for malformed, rejected, timed-out, and disconnected authentication
    When I try each session secret and then request protected operations
    Then none authenticates and no protected command is issued

  Scenario: Any sixteen-byte ASCII session secret is accepted and kept within the session
    Given a connected fake transport and an injected diagnostic sink
    When I authenticate with a valid synthetic secret containing punctuation and invalidate the session
    Then the secret appears in no public result, error description, or diagnostic event and is cleared

  Scenario: Device information preserves values and unavailable conditions
    Given authenticated fake transports with valid, zero, missing, malformed, unsupported, timed-out, and disconnected information traces
    When I request battery, firmware, storage, and state
    Then each field reports its traced value or specific unavailable condition without invention

  Scenario: Date lists preserve the completed reported sequence
    Given authenticated fake transports with provenance-labelled empty, repeated, malformed, incomplete, unsupported, and timed-out date traces
    When I list recording dates
    Then completed sequences preserve order and repeats while every incomplete sequence fails

  Scenario: File lists are complete and use only the request tuple fields
    Given authenticated fake transports with complete, malformed, count-mismatched, timed-out, and disconnected reference-derived file traces
    When I list recordings for a device-reported date
    Then only complete ordered date, timestamp, size, and calculated duration results succeed

  Scenario: Download follows the provisional reference boundary
    Given authenticated fake transports with successful, zero-size, stalled, sync-missing, malformed, timed-out, and disconnected download traces
    When I download a recording by its device request tuple
    Then only the trace crossing its announced size returns bytes beginning at the first MP3 sync marker

  Scenario: A connection permits one in-flight operation
    Given an authenticated fake transport with a suspended operation
    When I start a second public operation
    Then it fails immediately as busy without issuing its command and the first alone consumes frames

  Scenario: Cancellation and timeout retire their transport generation
    Given an authenticated fake transport with an operation that is cancelled or times out
    When late frames arrive and I attempt another operation
    Then the generation is retired, authentication is invalidated, and late frames cannot complete later work

  Scenario: Disconnect invalidates the session
    Given an authenticated fake transport with an active operation
    When the transport disconnects
    Then the operation fails as disconnected and protected commands require reconnect and reauthentication

  Scenario: Retry starts a whole read-only operation from zero
    Given a partial download followed by a newly authenticated transport generation
    When I retry the same recording
    Then only retry bytes are returned and no resume, delete, or modify command is emitted

  Scenario: Every operation is deterministically bounded
    Given silent fake transports for authentication, information, listing, and download
    When each operation reaches its configured deadline
    Then each finishes with its operation-specific timeout or stall failure without hardware time
