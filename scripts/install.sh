#!/usr/bin/env bash
# Build + bundle the companion APK and the macOS app (Release), then install to
# /Applications. The installed app serves this APK for QR onboarding, so the APK must be
# built and bundled INSIDE the .app before it's packaged — `all.sh --install` does both
# (companion APK → Resources/, then the Release app embeds it). Thin, discoverable wrapper.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/all.sh --install "$@"
