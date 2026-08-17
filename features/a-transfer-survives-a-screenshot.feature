Feature: Bringing a recording over survives a screenshot and a pocket

  Nick, with recordings waiting on his recorder: "if I do anything like screenshot or leave
  the page to go to another app it fails even the loading, which is an issue if this will take
  time to pull recordings over, it needs to be able to happen in the background."

  The cause was one comparison in the recorder page's own body — the errand was stopped for
  ANY scene phase that was not `.active`, and iOS reports `.inactive` for a screenshot, for
  Control Center, for the app switcher and for a notification banner. None of those is a person
  leaving. Several of them are things somebody does BECAUSE a transfer is running.

  There are two claims here and the second is the real one. Not cancelling is not the same as
  continuing: an app that goes to the background without asking the system for time is
  suspended within seconds, its Bluetooth callbacks stop and its transfer dies anyway — with
  the page still saying it is working. So a bring-over asks for the time to finish in, and
  gives it back on every way out: it finished, it failed, the owner left, or the system took
  the time back.

  These scenarios run inside the shipping app on a simulator and drive the recorder page's own
  model — the code in `App/`, which no other suite in this repository can execute. The radio is
  the scripted one; the system's background-time budget is the second thing a hermetic run
  cannot own, and it is the only other thing stood in for.

  Scenario: Taking a screenshot of a transfer does not stop the transfer
    Given a remembered recorder holding one recording
    And a transfer that is under way
    When something momentary interrupts the app
    Then the transfer is still under way
    And Solleva is still holding the recorder open
    And the transfer then finishes and Solleva keeps the recording

  Scenario: Putting the phone away mid-transfer does not stop the transfer
    Given a remembered recorder holding one recording
    And a transfer that is under way
    When I put the phone away
    Then the transfer is still under way
    And Solleva is still holding the recorder open
    And the transfer then finishes and Solleva keeps the recording

  Scenario: A transfer asks the system for the time to finish in
    Given a remembered recorder holding one recording
    And a transfer that is under way
    Then Solleva has asked the system for time to finish it
    And the transfer then finishes and Solleva keeps the recording

  Scenario: A transfer that finishes gives the time back
    Given a remembered recorder holding one recording
    And a transfer that is under way
    When the transfer is allowed to finish
    Then Solleva has given back every piece of time it asked for

  Scenario: A transfer that fails gives the time back
    Given a recorder Solleva cannot reach
    When I ask what that recorder is holding
    Then Solleva has given back every piece of time it asked for

  Scenario: Leaving the page still stops the transfer and gives the time back
    Given a remembered recorder holding one recording
    And a transfer that is under way
    When I leave the page
    Then the transfer is no longer under way
    And Solleva has given back every piece of time it asked for

  Scenario: A transfer the system will not make room for stops when the phone is put away
    Given a system that will not make room for anything to finish
    And a remembered recorder holding one recording
    And a transfer that is under way
    When I put the phone away
    Then the transfer is no longer under way
    And the record says it stopped because there was no time to finish in

  Scenario: When the system takes the time back the transfer stops instead of freezing
    Given a remembered recorder holding one recording
    And a transfer that is under way
    When the system takes the time back
    Then the transfer is no longer under way
    And Solleva has given back every piece of time it asked for
    And the record says it stopped because there was no time to finish in
