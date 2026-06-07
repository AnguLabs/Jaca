#!/usr/bin/env bash
# Build Squeeze with the full Xcode toolchain (xcode-select may point at CLT).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"
[ -d Squeeze.xcodeproj ] || xcodegen generate
exec xcodebuild \
  -project Squeeze.xcodeproj \
  -scheme Squeeze \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build
