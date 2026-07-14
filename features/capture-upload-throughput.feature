Feature: Phone capture backlog upload throughput

  FoundryX drains saved phone audio promptly while the computer door is reachable,
  so recent conversations do not sit partially transcribed for hours behind a
  large local segment backlog.

  Scenario: a connected phone continuously drains a large saved backlog
    Given a recent conversation has many saved segments waiting on the phone
    And the computer door is reachable
    When the phone starts the upload drain
    Then the conversation's saved segments are uploaded without waiting for hourly retries
    And multiple segment uploads may be in flight within the bounded upload limit
    And the conversation has no phone segments left waiting to upload
