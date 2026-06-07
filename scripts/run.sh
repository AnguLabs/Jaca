#!/usr/bin/env bash
# Build then launch the Squeeze .app.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"
[ -d Squeeze.xcodeproj ] || xcodegen generate
APP_PATH="$(xcodebuild \
  -project Squeeze.xcodeproj \
  -scheme Squeeze \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')"
./scripts/build.sh "$CONFIG"
echo "Launching $APP_PATH"
open "$APP_PATH"
