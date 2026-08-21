Feature: The owner can stop a transfer, and can empty the recorder in one go
  Two capabilities shipped as APIs with nobody able to reach them, and both were recorded as
  gaps by the agent that landed the queue rather than reported as delivered.

  `PocketTransferQueue.stop(_:)` had no production caller of any kind and `stopAll()` had one —
  inside lifecycle handling, not behind a button — so after a transfer was made to outlive the
  page, a pull had NO owner-reachable exit at all. Nick's requirement is the opposite: "only a
  stop button should stop the pull, or disconnecting or losing connection to the device".

  And the queue was only ever handed a one-element array, so "tap once and have the recorder
  emptied" never happened: every extra recording still cost another tap and another full
  Bluetooth handshake, which is the exact cost the queue exists to remove.

  Every scenario below is about WHICH CONTROLS THE PAGE OFFERS, which is a rule in the kit
  because `swift test` cannot compile `App/` — a control that existed only as a button there is
  a control no test in this repository can see, and that is how both of these shipped.

  Scenario: While a transfer is running, the owner can stop it
    Given a transfer is running on this recorder
    Then the page offers a control that stops the transfer
    And the page says what stopping would cost before it is pressed

  Scenario: With nothing running, there is no stop
    Given no transfer is running and the recorder holds recordings this phone does not
    Then the page offers no control that stops anything
    And no control the page offers is disabled while nothing is running

  Scenario: A backlog can be taken in one go, and the control says how many
    Given no transfer is running and the recorder holds recordings this phone does not
    Then the page offers a control that takes the whole backlog
    And that control names the number of recordings it would take

  Scenario: One recording is not a backlog
    Given no transfer is running and the recorder holds exactly one recording this phone does not
    Then the page offers no control that takes the whole backlog
    And the page still offers to bring that one recording over

  Scenario: The stop the control is wired to actually empties the queue
    Given a queue holding three recordings that have not started
    When the owner's stop is used
    Then no recording in the queue is still waiting its turn
    And none of them is offered to the queue again

  Scenario: The backlog is what the recorder holds minus what this phone already has
    Given a recorder listing four recordings, two of which this phone already holds
    Then the backlog is the two this phone does not hold
    And the backlog never contains a recording this phone is already holding

  # Found by the cross-vendor reviewer, 2026-08-20. The number on that control is what a person
  # consents to before spending a full-length Bluetooth transfer on each recording, so a number
  # larger than the set the tap actually takes is an invented cost. The design already forbade
  # resolving the count and the set two different ways; this disagreement arrives through the
  # LISTING instead, and the check above could not see it because it compared a Set.
  Scenario: A recorder that lists one recording twice does not offer to bring two over
    Given a recorder listing the same recording twice, which this phone does not hold
    Then the backlog holds that recording once
    And the number on the control is the number the queue would actually take

  Scenario: While some other errand holds the radio, the controls are dead but the stop is not
    Given a shelf check is running and the recorder holds recordings this phone does not
    Then no control the page offers can be tapped
    When a transfer is running as well
    Then the stop can be tapped even though the page is busy

  Scenario: A recording this phone already had did not come over anything
    Given a queue of five recordings that were all already on this iPhone
    Then the page does not say five were brought over
    And the page says five were already on this iPhone

  Scenario: A count that cannot be true of its own queue is not stated as a success
    Given a batch sentence asked for more brought over than the queue ever held
    Then the sentence never claims more than the queue held

  Scenario: A drain of many reports every one of them, and counts what is left
    Given a queue of five recordings where three were brought over and two were not
    Then every recording that arrived is handed to the capture owner
    And every recording that arrived is recorded against its own name
    And the page says three of five were brought over and two are still on the recorder
    And the sentence states no size, no rate and no estimate
