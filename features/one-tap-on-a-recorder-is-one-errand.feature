Feature: One tap on a recorder is one errand

  Bringing a recording over ended by asking the recorder everything again from the
  beginning — a second connect, a second proof of who we are, a second reading of the
  shelf — so one tap on the button cost two conversations with the device, and the second
  one bought nothing the first had not already paid for. Walking away in the middle bought
  even less: the errand carried on with nobody watching it, holding the radio open for a
  screen that had gone. And the slowest, most failure-prone thing this app does was the one
  errand whose record was thrown away, so on the day it failed there was nothing to read.

  These scenarios run inside the shipping app and drive the recorder page's own model. The
  only thing here that is not shipped code is the radio, which a hermetic run cannot own.

  Scenario: Bringing a recording over talks to the recorder once
    Given a remembered recorder holding two recordings
    And Solleva has asked that recorder what it is holding
    When I bring the offered recording over
    Then Solleva opened exactly one more session with that recorder
    And it never asked that recorder for its day list a second time

  Scenario: The shelf tells the truth afterwards without asking the recorder again
    Given a remembered recorder holding two recordings
    And Solleva has asked that recorder what it is holding
    When I bring the offered recording over
    Then the shelf says that recording is in Solleva
    And Solleva offers a different recording to bring over next

  Scenario: Walking away stops the errand
    Given a remembered recorder holding two recordings
    When I ask what the recorder is holding and leave the page before it answers
    Then Solleva is no longer holding that recorder open
    And anything the recorder says after that reaches nobody
    And Solleva is not still telling me it is checking

  Scenario: The errand leaves a record of what it did
    Given a remembered recorder holding two recordings
    And Solleva has asked that recorder what it is holding
    When I bring the offered recording over
    Then the record says an errand started and that it finished
    And the record says the recording was taken into Solleva's keeping

  Scenario: An errand that reaches nothing still leaves a record
    Given a recorder Solleva cannot reach
    When I ask what that recorder is holding
    Then the record says an errand started and that it finished
    And the record does not claim anything was taken into Solleva's keeping

  Scenario: What the page shows about a recorder is rebuilt only when something changed it
    Given a remembered recorder holding two recordings
    And Solleva has asked that recorder what it is holding
    When I bring the offered recording over
    Then Solleva rebuilt what it shows about that recorder exactly twice
