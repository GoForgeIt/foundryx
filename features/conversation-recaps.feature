Feature: Daily and weekly recaps of my conversations

  The app keeps a living recap of what I talked about. The daily recap is a full
  narrative plus insights, rebuilt each time a new conversation finishes
  processing that day, so it grows through the day. The weekly recap is the same
  richness across the week, refreshed at the end of the week and on demand for a
  week-to-date view. A recap only exists for a period that actually had
  conversations. Nothing is invented: the recap is composed from what was said.

  Scenario: a day with no conversations has no recap
    Given no conversations today
    Then there is no daily recap

  Scenario: the daily recap covers the day's conversations
    Given three conversations finished processing today
    When the daily recap is built
    Then it names how many conversations it covers
    And it has a narrative summary and insights

  Scenario: the daily recap is rebuilt after each new conversation
    Given a daily recap covering two conversations
    When a third conversation finishes processing
    Then the daily recap covers three conversations
    And its freshness reflects the newest conversation

  Scenario: the weekly recap rolls up the week
    Given conversations across several days this week
    When the weekly recap is built
    Then it covers all of the week's conversations
    And it has a narrative summary and insights

  Scenario: a week-to-date recap can be requested any time
    Given conversations earlier this week and today
    When a week-to-date recap is requested mid-week
    Then it covers everything from the week's start through now

  Scenario: insights come from the conversations, never invented
    Given conversations about a client call and a dentist appointment
    When the daily recap is built
    Then the insights mention the client call and the dentist appointment
    And no insight references a topic that was not discussed
