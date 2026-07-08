Feature: See library stats and conversation receipts

  FoundryX keeps enough local state on the phone to explain the user's library
  and to show what work happened for a single conversation, even while offline.

  Scenario: library stats show local totals and recent trends
    Given I have locally browsable conversations with metadata, transcripts, and speaker segments
    When I open Your library from the capture surface
    Then I see the total conversations in my local library
    And I see the total hours recorded
    And I see the average conversation length
    And I see the total speakers identified
    And I see the total words
    And I see conversations per day for the recent trend
    And I see hours recorded this week

  Scenario: conversation receipt shows what processed the conversation
    Given I have a processed conversation with recording metadata
    When I open the conversation detail
    Then I can expand a receipt for the conversation
    And I see the recording duration
    And I see that transcription used Deepgram in the cloud
    And I see that speakers were found on-device
    And I see that device processing cost is zero dollars
