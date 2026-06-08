#!/usr/bin/env bash
# Regenerate Jaca.xcodeproj from project.yml using XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec xcodegen generate
