#!/usr/bin/env bash
# Build, archive and export a signed App Store .ipa for Task Monster.
#
# Signing is MANUAL (ios/ExportOptions.plist), pinned to the team's Apple
# Distribution identity and the "Task Monster App Store" profile. The automatic
# style wants an Apple ID signed into Xcode.app and this release Mac has none
# ("No Accounts"); an App Store Connect API key does not rescue it either —
# cloud-managed signing refuses API-key auth ("Cloud signing permission error").
#
# Usage:
#   scripts/release_ios.sh            # build + archive + export .ipa
#   scripts/release_ios.sh --upload   # additionally upload to App Store Connect
#
# Upload uses altool with an App Store Connect API key: ASC_KEY_ID /
# ASC_ISSUER_ID (defaults below) with AuthKey_<ASC_KEY_ID>.p8 in
# ~/.appstoreconnect/private_keys/.
#
# Output: build/ios/ipa/task_monster.ipa

set -euo pipefail
cd "$(dirname "$0")/.."

FLUTTER=${FLUTTER:-/opt/homebrew/bin/flutter}
ARCHIVE=build/ios/archive/Runner.xcarchive
PROFILE_NAME="Task Monster App Store"
ASC_KEY_ID=${ASC_KEY_ID:-PVV887QV57}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-1623d92a-9373-42ee-8bca-9435f6df7f4d}

# Signing preflight. Both of these have gone missing before, and without it the
# failure only surfaces at the export step — after a full archive build.
echo "==> Signing preflight"
if ! security find-identity -v -p codesigning \
     | grep -q "Apple Distribution: DARUMATIC PTY LTD"; then
  echo "ERROR: no 'Apple Distribution: DARUMATIC PTY LTD' identity in the keychain." >&2
  echo "       A private key is never re-downloadable from Apple: import the .p12" >&2
  echo "       backup, or mint a new certificate." >&2
  exit 1
fi
if ! grep -qls "$PROFILE_NAME" \
     "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; then
  echo "ERROR: the '$PROFILE_NAME' provisioning profile is not installed." >&2
  echo "       Apple deletes profiles when their certificate is revoked. Run:" >&2
  echo "         python3 scripts/mint_ios_profile.py --replace" >&2
  exit 1
fi

echo "==> flutter build ios (release, no codesign)"
"$FLUTTER" build ios --release --no-codesign

echo "==> xcodebuild archive"
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release archive \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=iOS" \
  DEVELOPMENT_TEAM=76UL6RCLTT \
  -allowProvisioningUpdates -quiet

echo "==> xcodebuild -exportArchive (app-store-connect, manual signing)"
rm -rf build/ios/ipa
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath build/ios/ipa \
  -exportOptionsPlist ios/ExportOptions.plist \
  -quiet

ipa="build/ios/ipa/task_monster.ipa"
if [[ ! -f "$ipa" ]]; then
  echo "ERROR: expected IPA not found at ${ipa}" >&2
  exit 1
fi
echo "==> Exported: $ipa"

if [[ "${1:-}" == "--upload" ]]; then
  echo "==> Uploading to App Store Connect"
  xcrun altool --upload-app --type ios -f "$ipa" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "==> Upload complete. The build still has to be attached to a version"
  echo "    and submitted for review in App Store Connect."
fi
