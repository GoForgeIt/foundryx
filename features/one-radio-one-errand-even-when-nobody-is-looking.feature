Feature: One radio, one errand, even when nobody is looking

  The recorder allows one conversation at a time, and until now the app enforced that with a flag
  on the recorder page. That worked while a person tapping a button was the only way to start
  anything. A drain that runs in the background has no page — so the owner opening the recorder
  page would see nothing running and start a second conversation with the same recorder.

  Scenario: A background drain holds the radio against another background drain
    Given a drain running in the background
    When another background drain asks for the radio
    Then it is refused
    And it is told a background drain has it

  Scenario: The owner takes the radio from a background drain
    Given a drain running in the background
    When the owner taps something that needs the radio
    Then the owner gets it

  Scenario: A background drain does not take the radio from the owner
    Given the owner is using the radio
    When a background drain asks for the radio
    Then it is refused
    And it is told the owner has it

  Scenario: Letting go of the radio hands it back
    Given a drain running in the background
    When that drain finishes
    Then the radio is free
    And a background drain can have it again

  Scenario: A drain that was pushed aside cannot take the radio back by finishing
    Given a drain running in the background
    When the owner taps something that needs the radio
    And the pushed-aside drain finishes
    Then the owner still has the radio
