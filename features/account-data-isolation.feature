Feature: My recordings belong to my account, not to the phone

  Signing in must do more than open the door: everything FoundryX keeps for me —
  recordings, my voiceprint, who I've named, my activity and answers, my
  categories — belongs to the ACCOUNT that recorded it, not to the handset. A
  different account signing in on the same phone starts clean and can never read
  the previous account's data. Switching back restores my own library exactly.

  Nothing is ever deleted to achieve this: an existing library from before this
  rule simply becomes the library of the account that owns it.

  Scenario: a second account signing in sees none of my recordings
    Given the first Google account has two recorded conversations
    When the second Google account replaces it on this phone
    Then the replacement account's recording library is empty
    And files owned by the first Google account remain outside the replacement library

  Scenario: my library comes back when I sign in again
    Given both Google accounts have recorded distinct conversations on this phone
    When the original Google account returns after the switch
    Then only the original account's two conversations are visible again
    And the replacement account's conversation stays in its own library

  Scenario: my voiceprint and the people I named never cross accounts
    Given the original account has an owner voice sample and a named speaker
    When the other account opens its biometric and speaker library
    Then that account finds no owner voice enrollment
    And that account finds none of the original account's speaker names

  Scenario: an existing recording library is kept, never lost
    Given an unclaimed recording library exists from before account scoping
    When its verified owner completes sign-in
    Then the legacy recording is moved intact into the owner's library
    And the durable ownership claim prevents a later account from inheriting it

  Scenario: signing out does not expose the recording library
    Given a signed-in account owns conversations on this phone
    When that account signs out of FoundryX
    Then the signed-out recording view contains no account conversations

  Scenario: the provider is part of an account's identity
    Given Google has stored a conversation for a shared email address
    When Microsoft signs in with the same email address
    Then the Microsoft account receives a different empty library
    And the Google conversation remains only in the Google library

  Scenario: Apple re-authorization keeps the same library without returning email
    Given an Apple subject recorded a conversation on its first authorization with email
    When the same Apple subject authorizes again without an email address
    Then Apple resolves the original subject's recording library
    And the Apple library never resolves to the signed-out scope

  Scenario: canonically equivalent account text keeps one stable key
    Given a Google account first signs in with a decomposed Unicode address
    When that Google account returns with the canonically composed address
    Then both address representations resolve to one account library

  Scenario: chat conversations follow the account through an account round trip
    Given the first account has a durable chat named "First private chat"
    And the second account creates a durable chat named "Second private chat"
    When the first account reopens chat after the second account
    Then only "First private chat" returns for the first account
    And "Second private chat" remains absent from the first account's chat list

  Scenario: an existing chat file is claimed exactly once
    Given an unscoped chat file contains "Legacy private chat"
    When the first verified provider account claims existing private data
    Then "Legacy private chat" is moved into that account's chat store
    And a later provider account cannot claim the legacy chat file

  Scenario: locked background relaunch keeps authenticated audio with its owner
    Given an authenticated account persisted its opaque owner scope before device lock
    When a locked background relaunch cannot read the identity token
    Then restored audio still targets the authenticated owner's library
    And restored audio is never assigned to the signed-out library

  Scenario: a failed ownership claim prevents activation
    Given the legacy container cannot durably record its first ownership claim
    When a provider account attempts to activate that private library
    Then account activation fails before any usable private root is exposed

  Scenario: a migration collision has deterministic non-clobbering recovery
    Given legacy and scoped libraries contain different data at the same destination
    When the verified owner attempts the colliding migration
    Then migration reports the recovered collision to sign-in
    And both versions remain intact in deterministic owner-only locations

  Scenario: identity transitions clear account-bound glanceable and pending state
    Given the first account has a widget title and pending ambient broker content
    When the phone transitions from the first account to the second account
    Then the widget exposes an idle snapshot to the second account
    And the identity transition clears every pending broker value

  Scenario: the free on-device tier still updates glanceable state with no account
    Given FoundryX is signed out for free on-device capture
    When capture publishes its current glanceable state
    Then the free on-device tier exposes the current capture state

  Scenario: work started for one account cannot finish into another
    Given ambient answer work is suspended after starting for the first account
    When the second account becomes active before that work completes
    Then the stale first-account work is rejected at completion
    And no first-account answer is appended to the second account's ledger

  Scenario: an email fallback is retained when the provider later returns a subject
    Given a Google account first owns a recording library using its verified email
    When the same Google account later returns with a stable subject
    Then the account still resolves its original recording library
    And no second account library is created for the later subject

  Scenario: activation requires a durable read-back of its active owner
    Given publishing the active owner cannot be durably confirmed
    When a provider account attempts to activate that private library
    Then account activation fails before any usable private root is exposed

  Scenario: opaque provider subjects remain case-sensitive
    Given one Google subject differing only by case owns a recording
    When the other case-sensitive Google subject signs in
    Then the second subject receives a different empty library
    And the first subject's recording remains only in its original library

  Scenario: stale widget work cannot publish into a replacement account
    Given widget work is suspended after starting for the first account
    When the second account becomes active before the widget work completes
    Then the stale widget write is rejected at completion
    And the second account retains an idle widget snapshot

  Scenario: stale ambient outcomes cannot publish into a replacement account
    Given ambient dismissal work is suspended after starting for the first account
    When the second account becomes active before the dismissal completes
    Then the stale dismissal is rejected at completion
    And no first-account outcome is appended to the second account's ledger

  Scenario: stale chat tool activity cannot publish into a replacement account
    Given chat tool activity is suspended after starting for the first account
    When the second account becomes active before the tool activity completes
    Then the stale tool activity is rejected at completion
    And no first-account tool activity is appended to the second account's ledger

  Scenario: a stale Door transcript cannot be cached into a replacement account
    Given a Door transcript is suspended after starting for the first account
    When the second account becomes active before the transcript completes
    Then the stale transcript cache write is rejected at completion
    And the second account's chat cache contains no first-account transcript

  Scenario: an identity transition clears account-bound Live Activity state
    Given the first account has an active Live Activity with private content
    When the phone changes from the first account to the second account
    Then the first account's Live Activity is ended
    And no first-account title or transcript is exposed to the second account
