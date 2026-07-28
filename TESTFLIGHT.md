# Shipping FoundryX to TestFlight

The app is App-Store-ready locally (bundle id `com.goforgeit.foundryx`, team `ND7H73W8VZ`,
version 0.1.0 build 1, app icon, export-compliance + local-network keys set, automatic signing).
The only things that need **you** are Apple credentials — they are never committed.

## What you must provide (one-time)

An **App Store Connect API key** for team `ND7H73W8VZ` with **App Manager** (or Admin) role.
We already have two keys on disk (used for DMG notarization):

```
~/.appstoreconnect/private_keys/AuthKey_47S3XFDK6D.p8
~/.appstoreconnect/private_keys/AuthKey_TY9TX3FBAD.p8
```

Provide the matching **Issuer ID** (an account UUID) and confirm which key has upload rights:
App Store Connect → **Users and Access → Integrations → App Store Connect API** → the key's
Issuer ID is shown there. (A notarization-only key has a limited role and **cannot** upload to
TestFlight — if both are notarization-only, generate a new key with App Manager role.)

> Don't paste the Issuer ID/keys into chat — set them as env vars (below) or store via the secret
> manager. The `.p8` files and any profiles are gitignored.

## First run only — create the app record

```bash
cd ~/Development/foundryx
bundle install
ASC_KEY_ID=47S3XFDK6D \
ASC_ISSUER_ID=<your-issuer-uuid> \
ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_47S3XFDK6D.p8 \
  bundle exec fastlane register
```

This registers the bundle id and creates the FoundryX app in App Store Connect. (You can also do it
by hand in App Store Connect → Apps → + → New App, bundle id `com.goforgeit.foundryx`.)

## Before you push: one-time release-gated constant

**Device-record migration epoch.** `CaptureDeviceSidecar.migrationEpoch`
(`Sources/FoundryXKit/CaptureDeviceSidecar.swift`) is the instant device records began being
written *in a build a user can have*. It decides what the app says about a conversation that
carries **no** device record: recorded at-or-after it ⇒ *"its device record went missing"*;
before it ⇒ *"recorded before the upgrade"*.

It is currently pinned to a deliberately **late placeholder**, which is the safe direction —
late understates what is known, early accuses correct captures of a fault they never had. It
stays safe only while it is in the future.

> **On the release that first writes device records:** set `migrationEpoch` to that release's
> build timestamp (Unix seconds, UTC), and record which build it shipped in beside the
> constant. Do not derive it from a build date at runtime — two handsets would then classify
> the same synced archive differently, which is the one thing this value may not do.

`DeviceCompositionRootGateTests.testTheMigrationEpochHasNotSilentlyBecomeEarly` goes **red**
once the epoch is in the past, so a slipped release cannot let it become early in silence. If
it reds, move the constant — never the assertion.

## Push a build to TestFlight

```bash
cd ~/Development/foundryx
ASC_KEY_ID=47S3XFDK6D \
ASC_ISSUER_ID=<your-issuer-uuid> \
ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_47S3XFDK6D.p8 \
  bundle exec fastlane beta
```

This regenerates the Xcode project, builds Release (app-store, automatic provisioning via the team),
and uploads to TestFlight. Build number auto-increments from the git commit count (override with
`BUILD_NUMBER=`). After upload, add yourself as an internal tester in App Store Connect → TestFlight;
the build is testable on your iPhone via the TestFlight app once processing finishes (a few minutes).

## Notes / likely first-run iteration

- **Signing/provisioning:** the lane passes `-allowProvisioningUpdates`, so Xcode creates the App
  Store distribution cert + provisioning profile automatically the first time (needs the API key to
  have signing/cert rights). If it can't, create an "Apple Distribution" cert + an App Store profile
  for `com.goforgeit.foundryx` once in the Apple Developer portal, or run `fastlane match`.
- **Export compliance:** `ITSAppUsesNonExemptEncryption=false` is set, so TestFlight won't prompt.
- **Ruby/fastlane:** system Ruby is old (2.6); if `bundle install` is unhappy, use a newer Ruby
  (`brew install ruby` / rbenv) — fastlane itself is unchanged.
- **Local network:** the app dials your Mac's LAN door (`http://<mac-ip>:14288`) — fine for an
  internal TestFlight build; off-LAN reach is the M5 relay, not this build.
