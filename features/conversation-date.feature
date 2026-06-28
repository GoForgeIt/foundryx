Feature: FoundryX conversation list shows the REAL start date, in local time

  The conversation list groups + labels each conversation by WHEN IT ACTUALLY
  HAPPENED — its real start — in the device's local timezone. The date must never
  come from a processing/re-ingest timestamp (the door's last_at, Lore's in_lore_at)
  nor from app-launch time, so an old conversation re-ingested today does NOT jump to
  "Today", and an evening recording stays on its local calendar day. Near-silent
  captures that transcribe to the same generic phrase render distinctly.

  Background:
    Given a conversation's real start is recovered from, in order, its meta start,
      its durable card start, then its capture-id timestamp — never a processing time

  Scenario: an evening-local recording groups under its LOCAL day, not the UTC day
    Given a conversation whose real start is yesterday evening in the device's timezone
    And that same instant falls on the next calendar day in UTC
    When the list buckets it with the device-local calendar
    Then it groups under "Yesterday"
    And it would have wrongly grouped under "Today" if bucketed in UTC

  Scenario: a re-ingested old capture keeps its original date
    Given a capture started weeks ago that has no meta sidecar
    And its capture id encodes that original start
    When the capture is re-ingested today and its card processing timestamp bumps
    Then the conversation's displayed date is still its original start
    And it does NOT move to "Today"

  Scenario: writing a card stamps a durable start that re-ingest cannot move
    Given a door poll seeds a conversation's card with only a title
    Then the card is stamped with a durable start derived from the capture id
    And a later processing-time write never overwrites that durable start

  Scenario: duplicate generic titles render distinctly in the list
    Given two different near-silent captures both titled "Thank you"
    When they render in the list
    Then each shows its start time appended so they are visually distinct
    And a specific, content-bearing title renders unchanged
