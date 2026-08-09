Feature: Pocket recordings join the durable conversation pipeline
  Pocket is pulled after the fact and never enters a live capture path.

  Scenario: absence backs off and presence resets the cadence
    Given an attached Pocket is away
    When five presence misses occur, then one inventory succeeds, then another miss occurs
    Then the requested delays are 60, 120, 240, 300, 300, and 60 seconds

  Scenario: a backlog is ordered and processed as files arrive
    Given eligible Pocket candidates on multiple recorder days
    When Pocket sync receives the backlog
    Then newer days arrive first, shorter files break same-day ties, and each landed file starts processing immediately

  Scenario: durable custody is the import commit point
    Given complete, truncated, and malformed Pocket payloads
    When Pocket sync imports each payload
    Then only re-readable checksum-matched MP3 creates a mapping and downstream job

  Scenario: an interrupted transfer retries the same durable identity
    Given a Pocket pull that first returns a partial prefix
    When Pocket sync retries from byte zero and the same file is pulled again
    Then one capture, conversation, transcript, Lore lineage, and Activity lineage exist

  Scenario: recorder time is retained with clock-skew honesty
    Given trusted, pre-set-point, and future Pocket timestamps
    When Pocket sync assembles their conversations
    Then device time is used, uncertain time is labeled, and future grouping is clamped without losing the reported value

  Scenario: Pocket and Omi share finalized processing
    Given finalized Pocket and Omi audio at the durable boundary
    When ambient processing notices an action in each
    Then both use the same conversation and Activity flow and neither posts a content notification

  Scenario: recorder deletion is never automatic
    Given a verified durable Pocket import
    When sync, retry, retention, and downstream recovery run
    Then no recorder delete is issued and the shipped deletion promise remains visible

  Scenario: Pocket has no live recording behavior
    Given spies around all live capture boundaries
    When the complete Pocket sync lifecycle runs
    Then no FrameRouter, WAL, Live Activity, recording pill, or currently-recording state is reached
