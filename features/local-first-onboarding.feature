Feature: FoundryX is whole without a brain — local-first onboarding

  Phone-only tier per foundryx-hearth track 20260705T1100_foundryx_local_first_onboarding:
  one-time identity sign-in, then a complete zero-content-egress recorder — record,
  transcribe, title, summarize, browse, and chat over the whole local library, all
  on-device. Conversations live in an append-only local event log so connecting a
  brain later is a replay-seed, never a migration.

  Scenario: first launch requires a one-tap identity sign-in before anything else
    Given a fresh install that has never signed in
    When I launch the app
    Then I am asked to sign in with Apple, Google, or Microsoft
    And I cannot reach capture or chat until I sign in

  Scenario: signing in leads straight to capture with the privacy promise stated
    Given a fresh install that has never signed in
    When I sign in with an identity provider
    Then my name and email are captured to my account
    And I am asked for microphone permission
    And I land on the capture screen
    And I see that my recordings never leave this phone

  Scenario: creating an account records a signup we can see
    Given a fresh install that has never signed in
    When I sign in with an identity provider
    Then an account-created event is recorded on the account backend
    And it carries my name, email, and sign-in provider
    And it carries my coarse location, device model, and app version
    And it never carries any conversation content

  Scenario: signing in with Apple captures name and email on the first authorization
    Given a fresh install that has never signed in
    When I sign in with Apple for the first time
    Then my name and email from Apple are recorded on the account backend
    And signing in again later does not lose them

  Scenario: a conversation is captured, transcribed, titled, and summarized entirely offline
    Given I have signed in
    And the phone has no network connection
    When I record a conversation and stop
    Then the conversation is transcribed on-device
    And it receives an on-device title and summary
    And it appears as a browsable conversation card

  Scenario: no conversation content leaves the phone after sign-in
    Given I have signed in
    When I record, transcribe, and chat over my library
    Then no recording, transcript, or summary content is sent over the network

  @phase1
  Scenario: every conversation event is appended to the local event log
    Given I have signed in
    When I record a conversation and stop
    Then the capture, transcript, title, and summary are appended to the local event log
    And no prior event in the log is modified or deleted

  Scenario: local chat answers over the whole library with an honesty notice
    Given I have signed in
    And I have several transcribed conversations
    When I ask a question in chat that spans multiple conversations
    Then the answer draws on more than the open conversation
    And a persistent honesty notice says answers run entirely on my phone and may be inaccurate
    And a join-the-waitlist button is present on the chat surface

  Scenario: a phone without Apple Intelligence still records and transcribes
    Given I have signed in on a phone without Apple Intelligence hardware
    When I record a conversation and stop
    Then the conversation is transcribed on-device
    And instead of a title and summary I see an upgrade prompt to connect a brain

  Scenario: the brain picker defaults to just my phone
    Given I have signed in
    When I open the brain picker in settings
    Then "Just my phone" is the current choice
    And "My computer" is offered for pairing with the desktop app
    And "Foundry Cloud" is shown as coming soon with a waitlist

  Scenario: joining the waitlist is a one-tap flag on my existing account
    Given I have signed in
    When I tap join the waitlist
    Then a waitlist-joined event is recorded against my existing account on the backend
    And I am not asked to fill in a form

  Scenario: waitlist signups are visible with the who and the where
    Given several people have signed in and joined the waitlist
    When the team reviews the signup sheet
    Then each waitlist signup shows name, email, provider, company when inferable, and coarse location

  Scenario: connecting a computer brain seeds it with the local library
    Given I have signed in
    And I have transcribed conversations recorded phone-only
    When I connect my computer as the brain
    Then my local conversations are seeded into the brain by replaying the event log
    And my local conversations remain readable on the phone

  Scenario: disconnecting the brain returns to local-only with everything readable
    Given my computer is connected as the brain
    And my conversations have been enriched by the brain
    When I disconnect the brain
    Then all my conversations are still readable on the phone
