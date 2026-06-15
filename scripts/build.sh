#!/usr/bin/env bash
# Build Jaca with the full Xcode toolchain (xcode-select may point at CLT).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"
[ -d Jaca.xcodeproj ] || xcodegen generate
xcodebuild \
  -project Jaca.xcodeproj \
  -scheme Jaca \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build

# macOS Local Network privacy: the in-app NWBrowser only discovers the companion over mDNS if
# the app declares the service type in NSBonjourServices. That key is an array, which Xcode's
# INFOPLIST_KEY_ can't set, so inject it into the built Info.plist and re-seal (ad-hoc here;
# dev-resign below re-signs with the stable identity if set up).
APP="$(xcodebuild -project Jaca.xcodeproj -scheme Jaca -configuration "$CONFIG" \
  -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')"
PLIST="$APP/Contents/Info.plist"
if [ -f "$PLIST" ] && ! /usr/libexec/PlistBuddy -c "Print :NSBonjourServices" "$PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :NSBonjourServices array" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :NSBonjourServices:0 string _jaca._tcp" "$PLIST"
  codesign --force --sign - "$APP" >/dev/null 2>&1   # re-seal the modified bundle (ad-hoc)
  echo "✓ injected NSBonjourServices (_jaca._tcp) into Info.plist"
fi

# Re-sign with the stable "Jaca Dev" identity if it's set up (scripts/dev-signing.sh), so the
# keychain "Always Allow" for the CA key sticks across rebuilds. No-op otherwise (stays ad-hoc).
./scripts/dev-resign.sh "$CONFIG"
