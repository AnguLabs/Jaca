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

# Re-sign with the stable "Jaca Dev" identity if it's set up (scripts/dev-signing.sh), so the
# keychain "Always Allow" for the CA key sticks across rebuilds. No-op otherwise (stays ad-hoc).
./scripts/dev-resign.sh "$CONFIG"
