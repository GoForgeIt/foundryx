Feature: Every state the setup ceremony can put me in has a way out

  THE DEFECT CLASS, NOT ONE DEFECT. Six times now the answer has looked like "we never built
  it" and been "we built it and you can't get there from here". A screen exists, is
  implemented, is tested, and is reachable from ONE state while being orphaned from another
  the person actually lands in.

    * `.handshakeUnanswered` — a recorder that answers a wrong key with SILENCE — had no exits
      at all, while `.setupUnavailable` had three.
    * `PocketFactoryResetPresentation`, a whole screen with the cost stated before the maker's
      gesture and its provenance named, hung off the CONSENT screen only. That state means
      "Solleva holds no key", so it is the one state a recorder with a WRONG stored key can
      never produce — the exact owner the guidance is written for could not reach it.
    * "I already have this recorder's key" hung off the same state for the same reason.
    * `.didNotFinish` — what a recorder that REFUSED the key Solleva holds lands on — carried
      "Try again" as its FIRST, PRIMARY button. That title fell through the routing table's
      `default` arm and closed the entire connect sheet, under a body reading "Try again
      before you close this."

  WHAT THESE SCENARIOS ARE. They run inside the shipping app's own process and drive
  `RecordingDeviceAttachModel` — the object a tap in "Connect a device" runs, and the object
  that owns which ceremony screen a tap lands on. Every button is pressed BY ITS OWN TITLE
  through the app's real routing table, and every screen is read from the view's own
  `drawnActions`. A scenario that built the object graph itself would prove the logic and
  nothing about reachability, and reachability is the whole defect. The only thing here that
  is not shipped code is the radio and the Keychain, neither of which a hermetic run can own.

  WHAT IS DELIBERATELY NOT OFFERED ANYWHERE. There is no one-tap "forget this recorder". This
  firmware has no reset opcode, no unpair, and no way to read a key back out, so custody may
  hold the only copy of a key in existence — and the screen a wrong key produces is made of
  SILENCE, which proves nothing. The honest escape is to REPLACE the key, which the entry
  field does because `PocketSecretStore.save` overwrites, or to start the recorder over.

  Scenario: A recorder that refuses the key Solleva holds offers all three ways forward
    Given a recorder that refuses the key Solleva holds
    When I tap that recorder in the connect sheet
    Then Solleva puts up a screen rather than a caption
    And that screen offers to let me enter a key
    And that screen offers the maker's reset guidance
    And that screen offers to try the recorder again
    And nothing on that screen offers to forget the recorder's key

  Scenario: Try again on the refused-key screen asks the recorder rather than closing the flow
    Given a recorder that refuses the key Solleva holds
    When I tap that recorder in the connect sheet
    And I ask Solleva to try that recorder again
    Then the flow is still open on a screen with a way out
    And Solleva asked the recorder again rather than dismissing me

  Scenario: The maker's reset guidance is reachable from the refused-key screen
    Given a recorder that refuses the key Solleva holds
    When I tap that recorder in the connect sheet
    And I ask how to start the recorder over
    Then Solleva is showing me the maker's reset guidance

  Scenario: The key field is reachable from the refused-key screen
    Given a recorder that refuses the key Solleva holds
    When I tap that recorder in the connect sheet
    And I choose to enter a key I already have
    Then Solleva is showing me the key field

  Scenario: Every button on the refused-key screen does something or says it closes
    Given a recorder that refuses the key Solleva holds
    When I tap that recorder in the connect sheet
    Then every button on that screen either does something or says out loud that it closes

  Scenario: A recorder that says nothing at all offers all three ways forward
    Given a recorder that says nothing at all to the key Solleva holds
    When I tap that recorder in the connect sheet
    Then Solleva puts up a screen rather than a caption
    And that screen offers to let me enter a key
    And that screen offers the maker's reset guidance
    And that screen offers to try the recorder again
    And nothing on that screen offers to forget the recorder's key

  Scenario: The maker's reset guidance is reachable from the silent-recorder screen
    Given a recorder that says nothing at all to the key Solleva holds
    When I tap that recorder in the connect sheet
    And I ask how to start the recorder over
    Then Solleva is showing me the maker's reset guidance

  Scenario: Every button on the silent-recorder screen does something or says it closes
    Given a recorder that says nothing at all to the key Solleva holds
    When I tap that recorder in the connect sheet
    Then every button on that screen either does something or says out loud that it closes

  Scenario: An unclaimed recorder offers the decision, the key field and the reset guidance
    Given a recorder no app has claimed, and Solleva holds no key for it
    When I tap that recorder in the connect sheet
    Then Solleva puts up a screen rather than a caption
    And that screen offers to send a new key
    And that screen offers to let me enter a key
    And that screen offers the maker's reset guidance
    And Solleva sent that recorder no key at all

  Scenario: A recorder another app owns offers the key field and the reset guidance
    Given a recorder another app owns, and Solleva holds no key for it
    When I tap that recorder in the connect sheet
    And I confirm that Solleva should send a new key
    Then Solleva says the recorder already belongs to another app
    And that screen offers to let me enter a key
    And that screen offers the maker's reset guidance
    And every button on that screen either does something or says out loud that it closes

  Scenario: The maker's reset guidance is reachable after a refused mint
    Given a recorder another app owns, and Solleva holds no key for it
    When I tap that recorder in the connect sheet
    And I confirm that Solleva should send a new key
    And I ask how to start the recorder over
    Then Solleva is showing me the maker's reset guidance

  Scenario: A recorder that says yes to any key leaves me able to reach the other app's key
    Given a recorder that says yes to any key and goes on using the one it has
    When I tap that recorder in the connect sheet
    And I confirm that Solleva should send a new key
    Then Solleva says it cannot confirm the recorder took the key
    And that screen offers to let me enter a key
    And that screen offers the maker's reset guidance
    And that screen offers to try the recorder again
    And every button on that screen either does something or says out loud that it closes

  Scenario: Try connecting again on the unproven-mint screen actually connects
    Given a recorder that says yes to any key and goes on using the one it has
    When I tap that recorder in the connect sheet
    And I confirm that Solleva should send a new key
    And I ask Solleva to try connecting again
    Then Solleva asked the recorder again rather than dismissing me
    And the recorder joins my account

  Scenario: A Keychain that will not keep the key leaves the recorder untouched and offers a retry
    Given a recorder Solleva holds no key for, and secure storage on this iPhone refuses to keep one
    When I tap that recorder in the connect sheet
    And I confirm that Solleva should send a new key
    Then Solleva says this iPhone could not store the key
    And that screen offers to try the recorder again
    And every button on that screen either does something or says out loud that it closes
    And Solleva sent that recorder no key at all

  Scenario: A Keychain Solleva cannot read offers a retry and the key field, and never a new key
    Given a recorder Solleva may hold a key for, and secure storage on this iPhone cannot be read
    When I tap that recorder in the connect sheet
    Then Solleva says it cannot read its own key
    And that screen offers to try the recorder again
    And that screen offers to let me enter a key
    And that screen does not offer to send a new key
    And every button on that screen either does something or says out loud that it closes

  Scenario: The reset guidance I reach is the maker's gesture and says what it costs
    Given a recorder that says nothing at all to the key Solleva holds
    When I tap that recorder in the connect sheet
    And I ask how to start the recorder over
    Then the guidance states the cost before the gesture
    And the guidance says Solleva can neither perform it nor check it worked
    And the guidance can take me back to setting the recorder up

  Scenario: No screen in the whole ceremony offers to forget, reveal or export a key
    Given a recorder that says nothing at all to the key Solleva holds
    When I tap that recorder in the connect sheet
    Then no setup screen in the ceremony offers to forget, reveal, copy, share or export a key
