#!/usr/bin/env bash
# Re-sign the built .app with the stable "Jaca Dev" identity so the keychain "Always Allow"
# for the CA private key sticks across rebuilds. No-op (keeps the ad-hoc signature) if the
# identity isn't set up — run scripts/dev-signing.sh once to create it.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"
IDENTITY="Jaca Dev"
KC="$HOME/Library/Keychains/jaca-dev.keychain-db"

# Only if the stable identity exists; otherwise leave the ad-hoc signature in place.
security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY" || exit 0
security unlock-keychain -p jaca-dev "$KC" 2>/dev/null || true

APP="$(xcodebuild -project Jaca.xcodeproj -scheme Jaca -configuration "$CONFIG" \
  -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')"
[ -d "$APP" ] || { echo "re-sign: built app not found ($APP)"; exit 0; }

if codesign --force --deep --sign "$IDENTITY" --keychain "$KC" "$APP" >/dev/null 2>&1; then
  echo "✓ re-signed $(basename "$APP") with '$IDENTITY' (stable keychain access)"
else
  echo "⚠ re-sign with '$IDENTITY' failed; keeping ad-hoc signature"
fi
