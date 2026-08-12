#!/bin/bash
# Ported VERBATIM from ci/foundryx-ios-publish.yml task archive-rcodesign-upload
# (foundry repo) on 2026-08-12, as part of the GitHub Actions migration
# (foundry-business-hearth proposal 20260812T2204_github_actions_ci_migration).
# Expects sibling input dirs: foundryx-source/ grain/ brine-private-source/
# Env: ASC_API_KEY_P8 ASC_ISSUER_ID ASC_KEY_ID FOUNDRYX_PROVISION_PROFILE_BASE64
#      FOUNDRYX_WIDGET_PROVISION_PROFILE_BASE64 FOUNDRYX_SIGNING_PEM
set -euo pipefail
mkdir -p ipa-out
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
# $TASK_ROOT holds the ipa-out output dir.
TASK_ROOT="$PWD"
# Materialize foundryx + grain as REAL sibling dirs in a clean workdir.
# Concourse inputs are symlinks; `cd` into one resolves the link, so
# project.yml's SwiftPM path dep `../grain/...` breaks. Copying both out
# as real siblings makes the relative path resolve — same materialize
# pattern foundry-app-publish uses.
mkdir -p workdir/foundryx workdir/grain workdir/brine-private
tar -cf - -C foundryx-source . | tar -xf - -C workdir/foundryx
tar -cf - -C grain . | tar -xf - -C workdir/grain
tar -cf - -C brine-private-source . | tar -xf - -C workdir/brine-private
cd workdir/foundryx

# ── 0. Toolchain ──
command -v xcodegen  >/dev/null 2>&1 || brew install xcodegen
command -v rcodesign >/dev/null 2>&1 || cargo install apple-codesign

# ── 1. Generate project + UNSIGNED archive ──
# (xcodebuild BUILD works on the beta; only system codesign is broken.)
xcodegen generate
# Commit count ALONE is not monotonic against TestFlight: re-running an
# unchanged commit repeats a number, and it can also simply LAG what Apple
# already holds. Builds 96, 101, 102, 106, 107 and 108 each failed with
# "The bundle version must be higher than the previously uploaded version"
# AFTER a full build+sign+notarize — the phone was on 397 while this line
# produced less. (Three fixes were made to fastlane/Fastfile before noticing
# this job never calls that lane: it sets BUILD_NUMBER here and passes it to
# xcodebuild, so the Fastfile logic was dead code.)
#
# Floor above every build known to exist so an under-counting repo cannot
# collide, and keep the commit count when it eventually exceeds the floor.
# A STATIC floor collides the moment it is used once: build 111 shipped 500,
# then build 112 computed 500 again and Apple rejected it. Use a value that
# STRICTLY INCREASES on its own — elapsed minutes since a fixed epoch — so a
# rebuild of the same commit still gets a fresh, larger number and no lookup
# of Apple's state is required at all.
#
# 2026-08-06 is ~29,650,000 minutes after 1970; subtracting the offset keeps
# the value in the high-6-figure range rather than the tens of millions, while
# remaining monotonic forever. Never lower the offset: that would go backwards
# and Apple refuses a decrease.
BUILD_NUMBER="$(( $(date +%s) / 60 - 29000000 ))"
echo "==> CFBundleVersion = $BUILD_NUMBER"
ARCHIVE="${TMPDIR:-/tmp}/FoundryX.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project FoundryX.xcodeproj -scheme FoundryX -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

APP_SRC="$ARCHIVE/Products/Applications/FoundryX.app"
[ -d "$APP_SRC" ] || { echo "ERROR: archive has no FoundryX.app" >&2; exit 1; }

# ── 2. Stage Payload + embed provisioning profiles (app + widget) ──
WORK="${TMPDIR:-/tmp}/foundryx-ipa"
rm -rf "$WORK"; mkdir -p "$WORK/Payload"
cp -R "$APP_SRC" "$WORK/Payload/"
APP="$WORK/Payload/FoundryX.app"
printf '%s' "$FOUNDRYX_PROVISION_PROFILE_BASE64" | base64 --decode > "$APP/embedded.mobileprovision"
[ -s "$APP/embedded.mobileprovision" ] || { echo "ERROR: empty app embedded.mobileprovision" >&2; exit 1; }
WIDGET_APPEX="$APP/PlugIns/FoundryXWidget.appex"
[ -d "$WIDGET_APPEX" ] || { echo "ERROR: archive has no widget .appex at $WIDGET_APPEX" >&2; exit 1; }
printf '%s' "$FOUNDRYX_WIDGET_PROVISION_PROFILE_BASE64" | base64 --decode > "$WIDGET_APPEX/embedded.mobileprovision"
[ -s "$WIDGET_APPEX/embedded.mobileprovision" ] || { echo "ERROR: empty widget embedded.mobileprovision" >&2; exit 1; }

# ── 3. Materialize signing PEM + per-bundle App Store entitlements ──
SIGN_PEM="${TMPDIR:-/tmp}/foundryx-signing.pem"
printf '%s' "$FOUNDRYX_SIGNING_PEM" > "$SIGN_PEM"; chmod 600 "$SIGN_PEM"
# App entitlements — includes the App Group (needed for the Live Activity /
# widget shared snapshot) + keychain. Written via echo-block so YAML
# block-scalar indentation can't corrupt the plist.
ENT="${TMPDIR:-/tmp}/foundryx-entitlements.plist"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo '  <key>application-identifier</key><string>ND7H73W8VZ.com.goforgeit.foundryx</string>'
  echo '  <key>com.apple.developer.team-identifier</key><string>ND7H73W8VZ</string>'
  echo '  <key>com.apple.security.application-groups</key><array><string>group.com.goforgeit.foundryx</string></array>'
  echo '  <key>keychain-access-groups</key><array><string>ND7H73W8VZ.com.goforgeit.foundryx</string></array>'
  echo '  <key>get-task-allow</key><false/>'
  echo '</dict></plist>'
} > "$ENT"
# Widget extension entitlements — SAME group, its OWN application-identifier.
WIDGET_ENT="${TMPDIR:-/tmp}/foundryx-widget-entitlements.plist"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0"><dict>'
  echo '  <key>application-identifier</key><string>ND7H73W8VZ.com.goforgeit.foundryx.widget</string>'
  echo '  <key>com.apple.developer.team-identifier</key><string>ND7H73W8VZ</string>'
  echo '  <key>com.apple.security.application-groups</key><array><string>group.com.goforgeit.foundryx</string></array>'
  echo '  <key>keychain-access-groups</key><array><string>ND7H73W8VZ.com.goforgeit.foundryx.widget</string></array>'
  echo '  <key>get-task-allow</key><false/>'
  echo '</dict></plist>'
} > "$WIDGET_ENT"

# ── 4. Sign with rcodesign (bypasses the broken system codesign). The
#    scoped 'PlugIns/...appex:' entitlements OVERRIDE the app's for the
#    widget so it gets its own identifier; rcodesign reads each bundle's
#    embedded profile. ──
rcodesign sign \
  --pem-file "$SIGN_PEM" \
  --entitlements-xml-file "$ENT" \
  --entitlements-xml-file "PlugIns/FoundryXWidget.appex:$WIDGET_ENT" \
  "$APP"
rm -f "$SIGN_PEM"
# Verification still works on the beta — assert before upload.
codesign --verify --deep --strict "$APP"

# ── 5. Package .ipa ──
# rm any stale .ipa first — darwin Concourse tasks share the host TMPDIR,
# so a prior run's file makes `zip` try to update it and fail.
rm -rf "${TMPDIR:-/tmp}/FoundryX.ipa"
( cd "$WORK" && zip -qry "${TMPDIR:-/tmp}/FoundryX.ipa" Payload )
cp "${TMPDIR:-/tmp}/FoundryX.ipa" "$TASK_ROOT/ipa-out/"

# ── 6. Write ASC API key (TASK-LOCAL) + upload to TestFlight ──
# darwin Concourse tasks share the host $HOME, so write the key under a
# task-scoped dir (altool also searches ./private_keys relative to cwd)
# to avoid clobbering the operator's real key.
mkdir -p "$TASK_ROOT/private_keys"
ASC_KEY_PATH="$TASK_ROOT/private_keys/AuthKey_${ASC_KEY_ID}.p8"
printf '%s' "$ASC_API_KEY_P8" > "$ASC_KEY_PATH"; chmod 600 "$ASC_KEY_PATH"
# altool exits 0 even on "UPLOAD FAILED", so capture output + assert.
set +e
UPLOAD_OUT=$(cd "$TASK_ROOT" && xcrun altool --upload-app -f "${TMPDIR:-/tmp}/FoundryX.ipa" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1)
set -e
echo "$UPLOAD_OUT"
rm -f "$ASC_KEY_PATH"
if ! echo "$UPLOAD_OUT" | grep -q "UPLOAD SUCCEEDED"; then
  echo "ERROR: TestFlight upload failed (see altool output above)" >&2
  exit 1
fi
echo "==> FoundryX uploaded to TestFlight (build ${BUILD_NUMBER})"

# ── 7. VERIFY the build is INSTALLABLE, not merely uploaded ──
# "UPLOAD SUCCEEDED" only means Apple accepted the bytes. Processing can
# still fail, and a build that never reaches IN_BETA_TESTING is invisible
# to every tester while this job sits green. That ambiguity cost hours on
# 2026-07-31: CI said shipped, the tester's TestFlight showed the previous
# build, and nothing in the pipeline could tell those two states apart.
#
# openssl ONLY — no python crypto. The workers' system python3 is 3.9 with
# a broken user-site `cryptography`, and pyjwt is absent; depending on
# either would have failed EVERY ship. Verified on the worker host first.
ASC_PEM="$TASK_ROOT/private_keys/asc.pem"
mkdir -p "$TASK_ROOT/private_keys"
printf '%s' "$ASC_API_KEY_P8" > "$ASC_PEM"; chmod 600 "$ASC_PEM"
asc_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
asc_token() {
  local now exp hdr pay si der r s sig
  now=$(date +%s); exp=$((now + 1200))
  hdr=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ASC_KEY_ID" | asc_b64url)
  pay=$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' "$ASC_ISSUER_ID" "$now" "$exp" | asc_b64url)
  si="${hdr}.${pay}"
  der=$(mktemp)
  printf '%s' "$si" | openssl dgst -sha256 -sign "$ASC_PEM" > "$der"
  # JOSE wants raw r||s, 32 bytes each. openssl emits DER, so parse it out.
  r=$(openssl asn1parse -inform DER -in "$der" | awk -F: 'NR==2{print $NF}' | tr -d ' ')
  s=$(openssl asn1parse -inform DER -in "$der" | awk -F: 'NR==3{print $NF}' | tr -d ' ')
  rm -f "$der"
  sig=$( { printf '%064s' "$r" | tr ' ' 0; printf '%064s' "$s" | tr ' ' 0; } | tr -d '\n' | xxd -r -p | asc_b64url )
  printf '%s.%s' "$si" "$sig"
}
ASC_JQ='import sys,json;d=json.load(sys.stdin);w=sys.argv[1];t={i["id"]:i["attributes"] for i in d.get("included",[]) if i["type"]=="buildBetaDetails"};m=next((b for b in d.get("data",[]) if b["attributes"].get("version")==w),None);print("PENDING none") if not m else print(m["attributes"].get("processingState"), t.get(((m.get("relationships",{}).get("buildBetaDetail",{}) or {}).get("data") or {}).get("id"),{}).get("internalBuildState"))'
echo "==> waiting for build ${BUILD_NUMBER} to become installable"
INSTALLABLE=no
for _ in $(seq 1 40); do
  STATE=$(curl -s -H "Authorization: Bearer $(asc_token)" "https://api.appstoreconnect.apple.com/v1/builds?limit=20&include=buildBetaDetail" | /usr/bin/python3 -c "$ASC_JQ" "${BUILD_NUMBER}" || echo "QUERY_FAILED none")
  echo "    build ${BUILD_NUMBER}: ${STATE}"
  case "$STATE" in
    FAILED*|INVALID*) echo "ERROR: Apple rejected build ${BUILD_NUMBER} (${STATE})" >&2; rm -f "$ASC_PEM"; exit 1 ;;
    "VALID IN_BETA_TESTING") INSTALLABLE=yes; break ;;
  esac
  sleep 30
done
rm -f "$ASC_PEM"
if [ "$INSTALLABLE" != yes ]; then
  echo "ERROR: build ${BUILD_NUMBER} uploaded but never became installable." >&2
  echo "       No tester can install it, so this is a FAILED ship, not a green one." >&2
  exit 1
fi
echo "==> build ${BUILD_NUMBER} is INSTALLABLE by internal testers"