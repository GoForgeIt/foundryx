Feature: I enter the key my recorder was already set up with

  Track 20260811T0411_pocket_existing_key_entry. The adoption chain runs end to end and stops
  at one link: FoundryX can RESTORE a session key it already holds and may not MINT one, so
  every real tap on a recorder it has never provisioned lands on "Setup isn't available yet".
  An owner whose recorder was already set up by another app is not waiting on that gate — they
  have the key, and there was no way to hand it over.

  The honest fact this feature has to carry: the vendor app never displays that key. It
  receives it while pairing and keeps it, and the only way to read it is a one-time Bluetooth
  HCI capture — PacketLogger on macOS or iOS, the HCI snoop log and Wireshark on Android — a
  procedure documented by Pocket Libre. There is no screen to read it off and no sniffing
  shortcut, and the copy says so rather than sending someone hunting through settings.

  Driven against the real RecordingDeviceAttachment on the same BLE seam CoreBluetoothCentral
  wraps, the real PocketBLEClient handshake, the real PocketOnboardingCoordinator, the real
  adoption seam and an account-scoped RecordingDeviceStore. Nothing here mints a key.

  Scenario: the key I already have is kept and my recorder joins the list
    Given a signed-in account and a recorder that was set up by another app
    When I enter the key that recorder was set up with
    Then FoundryX keeps that key in secure custody
    And the recorder is adopted through the shipped chain
    And the redrawn list shows it as a peer row reading "Records on its own · Not connected"

  Scenario: a malformed key is refused before the recorder is sent a single byte
    Given a signed-in account and a recorder that was set up by another app
    When I enter a key that is the wrong length
    Then FoundryX sent that recorder nothing at all
    And it tells me a session key is sixteen characters and how many I entered
    And nothing was written to secure custody either
    When I enter a key that is not plain text
    Then FoundryX sent that recorder nothing at all
    And it tells me the key has characters the recorder's protocol cannot carry
    And a well-formed key does reach the recorder, so this refusal is not vacuous

  Scenario: a key the recorder refuses is not reported as a broken link
    Given a signed-in account and a recorder that was set up by another app
    When I enter a well-formed key that recorder was not set up with
    Then the recorder was asked and refused it
    And FoundryX says the recorder refused that key
    And that is a different answer from the one a recorder it cannot reach produces
    And it never tells me the recorder is not connected
    And the account does not remember that recorder

  Scenario: a key the recorder refused is not left in custody, so I can fix my typo
    Given a signed-in account and a recorder that was set up by another app
    When I enter a well-formed key that recorder was not set up with
    Then the key the recorder refused is not left in secure custody
    And the screen a refused key lands on still offers to let me enter a key
    When I enter the key that recorder was set up with
    Then the recorder is adopted through the shipped chain
    And FoundryX keeps that key in secure custody

  Scenario: the key is never on screen, in a snapshot, or in a keyboard's hands
    Given the shipped key-entry guidance
    Then the field hides the key as I type it
    And the screen is covered before the app is put in the background
    And the field does not hand what I type to a third-party keyboard
    And the field does not keep the key after it is submitted
    And it tells me how many characters I have entered without showing them

  Scenario: the key reaches no log, error, or diagnostic
    Given a signed-in account and a recorder that was set up by another app
    When I enter the key that recorder was set up with while every output is captured
    Then the key appears nowhere in the captured output
    And the key appears in no outcome value the app can render or print
    And the key appears in no line this screen can display
    And the captured output is not empty, so the search is not vacuous

  Scenario: the guidance says where the key actually comes from
    Given the shipped key-entry guidance
    Then it states outright that the vendor app never shows the key
    And it names the macOS and iOS capture route
    And it names the Android capture route
    And it rules out finding the key by sniffing the recorder
    And it attributes the procedure to Pocket Libre's documentation
    And it shows no example key and offers no way to reveal, copy, or export one

  Scenario: the setup-unavailable screen still stands when no key has been entered
    Given a signed-in account and a recorder that was set up by another app
    When I tap that recorder without entering a key
    Then the app says setup isn't available yet instead of adding a row
    And FoundryX sent that recorder nothing at all
    And the screen still offers to let me enter a key I already have
    And nothing in the app mints a key for a factory-fresh recorder
