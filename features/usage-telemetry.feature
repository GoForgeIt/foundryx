Feature: The app reports HOW it is used, content-free

  Today the app only reports its own PERFORMANCE. We also want to see how the
  product is actually used — which pages people visit, how many minutes they
  record, how many conversations happen, how many intelligent actions get
  generated and acted on, and how chat/Kiln is used — WITHOUT ever shipping a
  single word of content. Every value that leaves the phone is a count, a
  duration, or a controlled enum token. The stream is delivered THROUGH Foundry:
  the app POSTs newline-delimited JSON to the Foundry door, which appends it to
  the local foundryx telemetry rollup — the app never ships a rollup to the cloud.

  Scenario: visiting a page emits one content-free page event
    Given the usage stream is wired
    When the user moves to the chat page
    Then a "page" event is emitted whose page token is "chat"
    And the event carries no content

  Scenario: ending a recording emits a content-free session event
    Given the usage stream is wired
    When a recording session of 90 seconds ends and is kept
    Then a "session" event is emitted with a numeric duration of 90 seconds
    And it carries the source and kept as tokens/numbers, never the transcript

  Scenario: a generated intelligent action is counted, never quoted
    Given the usage stream is wired
    When the ambient lane generates a candidate from the live window
    Then a "generation" event is emitted with a duration and the window SIZE
    And neither the window text nor the candidate text is present

  Scenario: a completed chat turn is measured, never quoted
    Given the usage stream is wired
    When a chat turn routed to a local model completes
    Then a "chat" event is emitted with the model token, the local route, and timings
    And neither the prompt nor the response text is present

  Scenario: every usage event carries the build and an anonymous install id
    Given any usage event
    Then it carries the app build and a stable anonymous install id
    And it never carries personal data

  Scenario: any value that is actually free text is reduced to a safe token
    Given a usage event whose value contains punctuation, spaces, and emoji
    When it is serialized for shipping
    Then only safe token characters survive, capped at 64
