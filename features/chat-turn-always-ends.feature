Feature: a chat turn always ends, and leaves the app usable

  Sending is the thing I do most on this phone, and the phone is away from my Mac
  most of the time — so "my computer couldn't be reached" is the ORDINARY case, not
  an edge case. Either way the turn has to END: the reply, or the honest sentence
  about why there isn't one, lands in the thread; the finished turn is written into
  my chat history under the account that started it; and the composer comes back so
  I can leave, retry, or keep reading.

  Finishing a turn must never be able to freeze the app. It could: writing the
  finished turn into my history is account-scoped work that itself does account-
  scoped work, and the account gate was not re-entrant — so the main thread took a
  lock it was already holding and the app stopped answering entirely. Every scenario
  below that ends a turn is bounded by a deadline, so a return of that defect reads
  as a FAILURE and never as a suite that hangs.

  Scenario: a turn to a computer that cannot be reached still ends
    Given I am signed in on this phone
    And my computer cannot be reached
    When I send a chat turn
    Then the turn ends
    And the thread says my computer couldn't be reached
    And the composer is mine again

  Scenario: the finished turn is written into my chat history
    Given I am signed in on this phone
    And my computer answers
    When I send a chat turn
    Then the turn ends
    And my chat history holds the reply
    And what I asked appears once, not twice

  Scenario: a failed turn is still written into my chat history
    Given I am signed in on this phone
    And my computer cannot be reached
    When I send a chat turn
    Then the turn ends
    And my chat history holds what I asked

  Scenario: account-scoped work may do account-scoped work without freezing
    Given I am signed in on this phone
    When account-scoped work does account-scoped work
    Then the inner work runs
    And the screen was never blocked

  Scenario: work belonging to an account that is no longer current is refused
    Given I am signed in on this phone
    When account-scoped work from a superseded account does account-scoped work
    Then the work is refused
    And the screen was never blocked

  Scenario: a computer whose Kiln is not running says so, and does not say "try again"
    Given I am signed in on this phone
    And my computer answers but Kiln is not running
    When I send a chat turn
    Then the turn ends
    And the thread says Kiln isn't running on my computer

  Scenario: a computer that cannot reach its own Kiln says that instead
    Given I am signed in on this phone
    And my computer cannot reach its own Kiln
    When I send a chat turn
    Then the turn ends
    And the thread says my computer couldn't reach Kiln
