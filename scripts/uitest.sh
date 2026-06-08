#!/usr/bin/env bash
# Run the XCUITest suite reliably: clear stray app/test instances first (a common
# cause of "Running Background" activation flakiness), then run UI tests.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

pkill -9 -f "Jaca.app/Contents/MacOS/Jaca" 2>/dev/null || true
pkill -9 -f "Jaca.xctest" 2>/dev/null || true
sleep 1

[ -d Jaca.xcodeproj ] || xcodegen generate
exec xcodebuild \
  -project Jaca.xcodeproj -scheme Jaca -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -only-testing:JacaUITests test
