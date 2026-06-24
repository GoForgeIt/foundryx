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
#   - ~/.appstoreconnect/private_keys/AuthKey_TY9TX3FBAD.p8  (altool finds it here)
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME=FoundryX
PROJECT=FoundryX.xcodeproj
APIKEY=TY9TX3FBAD                                   # public ASC API key id
APIISSUER=6515707a-bc3b-4391-a626-8997a04d3afa      # public ASC issuer id
BUNDLE_ID=com.goforgeit.foundryx
TEAM_ID=ND7H73W8VZ
BUILD_NUM="$(git rev-list --count HEAD)"

echo "==> FoundryX TestFlight ship — build #$BUILD_NUM"

# 1. Regenerate the Xcode project from project.yml (xcodegen).
echo "==> xcodegen generate"
xcodegen generate >/dev/null

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

# 3. Embed the provisioning profile.
cp build/signing/FoundryX_AppStore.mobileprovision "$APP/embedded.mobileprovision"

# 4. Build the signing chain: PRIVATE KEY + leaf cert + WWDR G3 intermediate.
#    (dist.pem holds ONLY the leaf cert; the key lives in dist.key — rcodesign needs
#    both, plus the intermediate, or App Store rejects "not an Apple submission cert".)
openssl x509 -inform DER -in build/signing/AppleWWDRCAG3.cer -out build/wwdrg3.pem 2>/dev/null
cat build/signing/dist.key build/signing/dist.pem build/wwdrg3.pem > build/sign-chain.pem

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
	<key>get-task-allow</key>
	<false/>
</dict>
</plist>
PLIST

# 6. Sign with rcodesign.
echo "==> rcodesign sign"
~/.cargo/bin/rcodesign sign \
  --pem-file build/sign-chain.pem \
  --entitlements-xml-file build/entitlements-min.xml \
  --code-signature-flags runtime \
  "$APP" 2>&1 | grep -iE "cryptographic signature|error" || true

# 7. Package the IPA.
echo "==> package IPA"
mkdir -p build/Payload && cp -R "$APP" build/Payload/
( cd build && zip -qry FoundryX.ipa Payload )

# 8. Upload to TestFlight.
echo "==> altool upload-app"
xcrun altool --upload-app -f build/FoundryX.ipa -t ios \
  --apiKey "$APIKEY" --apiIssuer "$APIISSUER"

echo "==> DONE — build #$BUILD_NUM uploaded to TestFlight."
