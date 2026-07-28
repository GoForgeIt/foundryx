#!/usr/bin/env bash
# Ship FoundryX to TestFlight via rcodesign (bypasses the macOS-beta codesign bug,
# errSecInternalComponent). One command: archive → sign → IPA → upload.
#
# Build number == git commit count (must be unique per TestFlight upload). If a
# number is already used, bump MARKETING_VERSION in project.yml and re-run.
#
# Prereqs (already on this Mac):
#   - ~/.cargo/bin/rcodesign
#   - build/signing/dist.key  (Apple Distribution private key, PEM)
#   - build/signing/dist.pem  (Apple Distribution leaf cert, PEM)
#   - build/signing/AppleWWDRCAG3.cer  (WWDR G3 intermediate, DER — issuer of the leaf)
#   - build/signing/FoundryX_AppStore.mobileprovision
#   - build/signing/FoundryX_Widget_AppStore.mobileprovision  (widget extension)
#   - ~/.appstoreconnect/private_keys/AuthKey_TY9TX3FBAD.p8  (altool finds it here)
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME=FoundryX
PROJECT=FoundryX.xcodeproj
APIKEY=TY9TX3FBAD                                   # public ASC API key id
APIISSUER=6515707a-bc3b-4391-a626-8997a04d3afa      # public ASC issuer id
BUNDLE_ID=com.goforgeit.foundryx
WIDGET_BUNDLE_ID=com.goforgeit.foundryx.widget
TEAM_ID=ND7H73W8VZ
# Build number defaults to the commit count; pass an explicit one as $1 when the
# count collides with an already-uploaded build (e.g. shipping from a branch whose
# count trails a previous upload): ./scripts/ship-ios.sh 134
BUILD_NUM="${1:-$(git rev-list --count HEAD)}"

echo "==> FoundryX TestFlight ship — build #$BUILD_NUM"

# 1. Regenerate the Xcode project from project.yml (xcodegen).
echo "==> xcodegen generate"
xcodegen generate >/dev/null

# 1b. Retain per-build dSYMs BEFORE the previous archive is clobbered below.
#     b229's dSYM was lost forever to that rm (which crippled hang-report
#     symbolication — track 20260717T0759); never again. Keyed by
#     CFBundleVersion + binary UUID so every TestFlight build keeps an
#     atos-able dSYM in build/dsyms/<version>-<uuid>/. Keep all; never delete.
retain_dsyms() {
  local archive="$1"
  local dsym="$archive/dSYMs/FoundryX.app.dSYM"
  local bin="$dsym/Contents/Resources/DWARF/FoundryX"
  [ -f "$bin" ] || return 0
  local ver uuid dest
  ver="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' \
        "$archive/Info.plist" 2>/dev/null || echo unknown)"
  uuid="$(dwarfdump --uuid "$bin" 2>/dev/null | head -1 | awk '{print $2}')"
  [ -n "$uuid" ] || uuid=nouuid
  dest="build/dsyms/${ver}-${uuid}"
  [ -d "$dest" ] && return 0   # already retained — idempotent
  mkdir -p "$dest"
  cp -R "$archive/dSYMs/." "$dest/"
  echo "==> retained dSYMs → $dest"
}
retain_dsyms build/FoundryX.xcarchive

# 2. Unsigned archive (rcodesign signs afterward; Xcode signing is disabled).
echo "==> xcodebuild archive (unsigned, CFBundleVersion=$BUILD_NUM)"
rm -rf build/FoundryX.xcarchive build/Payload build/FoundryX.ipa
xcodebuild archive \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath build/FoundryX.xcarchive \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  >/dev/null
APP="build/FoundryX.xcarchive/Products/Applications/FoundryX.app"
[ -d "$APP" ] || { echo "archive produced no .app"; exit 1; }

# 2b. Retain the NEW build's dSYMs immediately — don't depend on the next ship run
#     happening before anything else clobbers the archive.
retain_dsyms build/FoundryX.xcarchive

# 3. Embed the provisioning profiles (app + widget extension).
cp build/signing/FoundryX_AppStore.mobileprovision "$APP/embedded.mobileprovision"
WIDGET_APPEX="$APP/PlugIns/FoundryXWidget.appex"
[ -d "$WIDGET_APPEX" ] || { echo "archive produced no widget .appex at $WIDGET_APPEX"; exit 1; }
cp build/signing/FoundryX_Widget_AppStore.mobileprovision "$WIDGET_APPEX/embedded.mobileprovision"

# 4. Signing chain — LEGACY PATH, only when the exported PEM material is present.
#    The identity now comes from the login keychain (see step 6), which already carries
#    the leaf + intermediate, so this is skipped when dist.key/dist.pem are absent.
#    They ARE absent by default: build/ is gitignored and a clean removes them, and the
#    private key cannot be recovered from disk (2026-07-28).
if [ -f build/signing/dist.key ] && [ -f build/signing/dist.pem ]; then
  openssl x509 -inform DER -in build/signing/AppleWWDRCAG3.cer -out build/wwdrg3.pem 2>/dev/null
  cat build/signing/dist.key build/signing/dist.pem build/wwdrg3.pem > build/sign-chain.pem
else
  # Keychain path: pull the WWDR G3 intermediate (a PUBLIC cert) straight from the
  # keychain, so a `build/` clean cannot leave this repo unable to ship.
  security find-certificate -a -c "Apple Worldwide Developer Relations" -p 2>/dev/null \
    | awk '/BEGIN CERT/{n++} n==2' > build/wwdrg3.pem
  openssl x509 -noout -subject -in build/wwdrg3.pem >/dev/null 2>&1 \
    || { echo "could not extract the WWDR intermediate from the keychain" >&2; exit 1; }
fi

# 5. MINIMAL CONCRETE entitlements. The wildcard profile-template entitlements
#    (associated-domains=*, ubiquity-kvstore=TEAM.*, push-to-talk, iCloud) are
#    rejected on a real binary; the app's BLE/audio/local-net/location/mic
#    capabilities come from Info.plist (UIBackgroundModes + usage strings), not
#    entitlements. Only app-id, team, app-group, keychain, get-task-allow are needed.
cat > build/entitlements-min.xml <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>${TEAM_ID}.${BUNDLE_ID}</string>
	<key>com.apple.developer.team-identifier</key>
	<string>${TEAM_ID}</string>
	<key>com.apple.security.application-groups</key>
	<array><string>group.${BUNDLE_ID}</string></array>
	<key>keychain-access-groups</key>
	<array><string>${TEAM_ID}.${BUNDLE_ID}</string></array>
	<key>com.apple.developer.applesignin</key>
	<array><string>Default</string></array>
	<key>get-task-allow</key>
	<false/>
</dict>
</plist>
PLIST

# 5b. Widget extension entitlements — SAME app group, but its OWN application-identifier
#     (com.goforgeit.foundryx.widget). A nested .appex signed with the app's identifier is
#     rejected by App Store, so this is applied scoped to the .appex path below.
cat > build/entitlements-widget.xml <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>${TEAM_ID}.${WIDGET_BUNDLE_ID}</string>
	<key>com.apple.developer.team-identifier</key>
	<string>${TEAM_ID}</string>
	<key>com.apple.security.application-groups</key>
	<array><string>group.${BUNDLE_ID}</string></array>
	<key>keychain-access-groups</key>
	<array><string>${TEAM_ID}.${WIDGET_BUNDLE_ID}</string></array>
	<key>get-task-allow</key>
	<false/>
</dict>
</plist>
PLIST

# 6. Sign with rcodesign. The unscoped entitlements apply to the app (and, by default, all
#    nested entities); the scoped 'PlugIns/...appex:' entry OVERRIDES them for the widget so
#    it gets its own application-identifier. rcodesign reads each bundle's embedded profile.
echo "==> rcodesign sign (app + widget)"
# Signs from the LOGIN KEYCHAIN, not from an exported PEM chain. build/signing/dist.key
# (the Apple Distribution PRIVATE KEY) is gitignored and was lost in a `build/` clean on
# 2026-07-28 — it exists nowhere on disk, only in the keychain. Re-exporting it needs a
# GUI prompt, so the durable fix is to stop depending on the export at all.
# Fingerprint: Apple Distribution: Nicholas Rinard (ND7H73W8VZ).
# The keychain supplies the PRIVATE KEY + leaf; --pem-file adds the WWDR intermediate.
# Both are required: without the intermediate the App Store rejects the upload with
# "not signed using an Apple submission certificate" (error 90034). The intermediate is
# extracted from the keychain at step 4 — it is a public cert, always available there.
~/.cargo/bin/rcodesign sign \
  --keychain-fingerprint 7DF5FFBDAD7DC8D701E711470F2127D9318A6D3DA2B0EEC5C801CB748CA5426A \
  --pem-file build/wwdrg3.pem \
  --entitlements-xml-file build/entitlements-min.xml \
  --entitlements-xml-file "PlugIns/FoundryXWidget.appex:build/entitlements-widget.xml" \
  --code-signature-flags runtime \
  "$APP" 2>&1 | tee build/rcodesign.log | grep -iE "cryptographic signature|error" || true
# FAIL LOUDLY on a signing error. This previously piped to `|| true` and swallowed
# everything, so a flag error meant an UNSIGNED app was packaged and uploaded — Apple
# rejected it with the confusing "not signed using an Apple submission certificate"
# (90034) two builds in a row before the real cause was visible (2026-07-28).
if grep -qiE "^error:|cannot be used with" build/rcodesign.log; then
  echo "rcodesign FAILED — refusing to package an unsigned app:" >&2
  grep -iE "^error:|cannot be used with" build/rcodesign.log >&2
  exit 1
fi
grep -qi "cryptographic signature" build/rcodesign.log || {
  echo "rcodesign produced NO signature — refusing to upload" >&2; exit 1; }

# 7. Package the IPA.
echo "==> package IPA"
mkdir -p build/Payload && cp -R "$APP" build/Payload/
( cd build && zip -qry FoundryX.ipa Payload )

# 8. Upload to TestFlight.
echo "==> altool upload-app"
xcrun altool --upload-app -f build/FoundryX.ipa -t ios \
  --apiKey "$APIKEY" --apiIssuer "$APIISSUER"

echo "==> DONE — build #$BUILD_NUM uploaded to TestFlight."
