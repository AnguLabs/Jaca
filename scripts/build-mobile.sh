#!/usr/bin/env bash
set -euo pipefail

# Builds the Jaca companion APK and bundles it into Resources/ for the desktop's
# one-step install + QR onboarding. Writes the git commit hash into BOTH the APK
# (BuildConfig.COMMIT_HASH, reported over gRPC) and a sidecar version file the
# desktop reads, so a connected device running an older build can be detected and
# the user prompted to update.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HASH="$(git -C "$ROOT" rev-parse --short HEAD)"

echo "==> Building companion APK at $HASH"
(cd "$ROOT/mobile" && ./gradlew :composeApp:assembleDebug -PcommitHash="$HASH" --no-configuration-cache)

APK="$ROOT/mobile/composeApp/build/outputs/apk/debug/composeApp-debug.apk"
cp "$APK" "$ROOT/Resources/jaca-mobile.apk"
printf '%s' "$HASH" > "$ROOT/Resources/jaca-mobile.apk.version"

echo "==> Bundled Resources/jaca-mobile.apk ($HASH, $(du -h "$ROOT/Resources/jaca-mobile.apk" | cut -f1))"
