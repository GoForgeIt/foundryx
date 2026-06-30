# iOS TestFlight CI — required GitHub secrets

The `iOS TestFlight` workflow (`.github/workflows/ios-testflight.yml`) signs with
rcodesign exactly like `scripts/ship-ios.sh` and uploads to TestFlight. It needs your
signing assets as **repository secrets**. Add them at:

> GitHub → repo → Settings → Secrets and variables → Actions → **New repository secret**

Generate each value from your local files (the `| pbcopy` puts the base64 on your
clipboard — paste it as the secret value):

| Secret name | Generate it with |
|---|---|
| `APPLE_DIST_KEY_B64` | `base64 -i build/signing/dist.key \| pbcopy` |
| `APPLE_DIST_CERT_B64` | `base64 -i build/signing/dist.pem \| pbcopy` |
| `APPLE_WWDR_G3_B64` | `base64 -i build/signing/AppleWWDRCAG3.cer \| pbcopy` |
| `FOUNDRYX_APP_PROFILE_B64` | `base64 -i build/signing/FoundryX_AppStore.mobileprovision \| pbcopy` |
| `FOUNDRYX_WIDGET_PROFILE_B64` | `base64 -i build/signing/FoundryX_Widget_AppStore.mobileprovision \| pbcopy` |
| `ASC_API_KEY_B64` | `base64 -i ~/.appstoreconnect/private_keys/AuthKey_TY9TX3FBAD.p8 \| pbcopy` |

The ASC API key id (`TY9TX3FBAD`) and issuer id are **not secret** — they're hardcoded
in `ship-ios.sh`. Only the `.p8` key file content is sensitive.

## ⚠️ Security
- `APPLE_DIST_KEY_B64` is your **Apple Distribution private key** — treat it like a
  password. GitHub encrypts secrets at rest and masks them in logs, but anyone with
  repo admin can read workflow behavior — keep the repo's admin list tight.
- If any of these leak, revoke the cert/key in the Apple Developer portal and rotate.

## What triggers a deploy
Once all six secrets are set, **every push to `main`** that touches `Sources/`, `App/`,
`Widget/`, `project.yml`, or the ship script auto-builds, signs the **app + widget**,
and uploads to TestFlight. You can also run it on demand: Actions → **iOS TestFlight**
→ Run workflow.

The build number is `git rev-list --count HEAD` (monotonic with commits). If TestFlight
rejects a duplicate build number, bump `MARKETING_VERSION` in `project.yml`.
