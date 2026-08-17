Feature: I make a brand-new recorder mine, and Solleva proves it

  A recorder that nobody has claimed can be claimed — the first key written to it becomes its
  key, which is how a factory-fresh unit was provisioned on hardware with no maker app, no
  account and no computer involved. That is the normal path and it has to genuinely work.

  Two things make it dangerous rather than routine. This firmware has no reset, no unpair and
  no way to read a key back out, so a key that is lost is a recorder nobody can ever talk to
  again — which is why the key is put into secure storage BEFORE it is ever sent to the
  recorder, and why nothing is sent at all if storage refuses it. And nobody has ever watched a
  recorder that ALREADY has a key receive a second one: it may refuse, or it may quietly take
  the new key and forget the old one. So the write is never attempted without the owner saying
  yes to it in front of the facts, a bare "OK" from the recorder is never taken as proof that
  anything happened, and a phone that merely cannot READ its own key is never walked into
  making a second one.

  Driven against the real RecordingDeviceAttachment on the same BLE seam CoreBluetoothCentral
  wraps, the real PocketBLEClient handshake, the real PocketOnboardingCoordinator, the real
  adoption seam and an account-scoped RecordingDeviceStore. The only injected things are the
  radio and the two custody stores.

  Scenario: a recorder nobody has claimed becomes mine
    Given a signed-in account and a recorder nobody has ever claimed
    When I confirm that Solleva should set this recorder up
    Then the recorder is holding the key Solleva made
    And Solleva checked the recorder's own WiFi password before calling it set up
    And the recorder is adopted through the shipped chain
    And Solleva keeps that key where I can get it back

  Scenario: a recorder that only says yes is not called set up
    Given a signed-in account and a recorder that says yes to any key and changes nothing
    When I confirm that Solleva should set this recorder up
    Then Solleva does not tell me the recorder is set up
    And the account does not remember that recorder
    And Solleva still keeps the key, because the recorder might be holding it
    And it tells me it could not confirm the recorder took the key

  Scenario: a recorder that will not report its WiFi is not called set up either
    Given a signed-in account and a recorder that never reports its WiFi
    When I confirm that Solleva should set this recorder up
    Then Solleva does not tell me the recorder is set up
    And Solleva still keeps the key, because the recorder might be holding it

  Scenario: a recorder that already belongs to another app says so, and nothing changes
    Given a signed-in account and a recorder another app already claimed
    When I confirm that Solleva should set this recorder up
    Then the recorder is still holding the key the other app gave it
    And Solleva tells me the recorder already belongs to another app
    And it offers me the key I already have and the way to start the recorder over
    And Solleva sent that recorder exactly one key and no more

  Scenario: nothing is written to a recorder until I say so
    Given a signed-in account and a recorder nobody has ever claimed
    When I tap that recorder without confirming anything
    Then Solleva sent that recorder nothing at all
    And the recorder is still holding no key
    And Solleva asks me to confirm, and says what it cannot predict

  Scenario: a key this iPhone cannot store is never sent to the recorder
    Given a signed-in account, a recorder nobody has claimed, and storage that fails once
    When I confirm that Solleva should set this recorder up
    Then Solleva sent that recorder nothing at all
    And the recorder is still holding no key
    And Solleva tells me this iPhone could not store the key
    When I confirm that Solleva should set this recorder up
    Then the recorder is adopted through the shipped chain
    And the key is kept and the recorder is adopted, and no second key was ever sent

  Scenario: a key Solleva cannot read is not a key Solleva does not have
    Given a signed-in account and a recorder whose stored key cannot be read
    When I tap that recorder without confirming anything
    Then Solleva sent that recorder nothing at all
    And Solleva says it cannot read its own key and does not offer to make a new one

  Scenario: the key Solleva makes is one the recorder's WiFi can actually use
    Given the key Solleva makes for a new recorder
    Then it is sixteen characters the recorder's protocol can carry
    And the characters a WiFi network will see are ones it will accept
    And two keys made one after another are never the same
    And it contains no character that would split the recorder's own commands

  Scenario: a key I can get back, on this phone and on my next one
    Given a signed-in account and a recorder nobody has ever claimed
    When I confirm that Solleva should set this recorder up
    Then I can see this recorder's key on a screen of its own
    And a new phone with the same Apple Account can recover it
    And a phone that has never seen this recorder connects with the key I already own
    And it doesn't promise me a key on my next phone when there isn't one
    And the key is not shown until I ask for it
    And forgetting the recorder removes both copies of the key

  Scenario: the key reaches no log, error, or diagnostic
    Given a signed-in account and a recorder nobody has ever claimed
    When I confirm that Solleva should set this recorder up while every output is captured
    Then the key appears nowhere in the captured output
    And the key appears in no line any of these screens can display
    And the captured output is not empty, so the search is not vacuous

  Scenario: starting the recorder over is explained with the cost first
    Given the shipped guidance for starting a recorder over
    Then it tells me what it costs me before it tells me how
    And it says Solleva cannot do it for me
    And it says Solleva cannot check whether it worked
    And it says where the steps came from

  Scenario: none of this claims the recorder is recording
    Given every screen this setup can show me
    Then none of them says the recorder is recording or in range
    And none of them puts this recorder on my lock screen
    And none of them reports a battery level Solleva did not just read
