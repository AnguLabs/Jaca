#!/usr/bin/env bash
# Build Jaca with the full Xcode toolchain (xcode-select may point at CLT).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-Debug}"

# --- In-process Android agent (.so + dexes) -------------------------------
# The agent IS part of the product — agent mode is the default network-inspection path — so
# building it lives here, in build.sh, not just in all.sh: a plain `build.sh` must never produce
# an incomplete app (the same guarantee the iOS-Simulator agent already gets from its xcodebuild
# build phase). Built only when missing or when its sources changed, so the inner app-rebuild
# loop doesn't pay the NDK/kotlinc cost every time. arm64-v8a only (every dev is on Apple
# Silicon; device + emulator share the ABI).
AGENT_SO=agent/out/arm64-v8a/libsqueezeagent.so
AGENT_BOOT=agent/out/squeezeagent-boot.dex
AGENT_CAP=agent/out/squeezeagent-capture.dex

agent_needs_build() {
  [ -f "$AGENT_SO" ] && [ -f "$AGENT_BOOT" ] && [ -f "$AGENT_CAP" ] || return 0   # any artifact missing
  [ -n "$(find agent/native agent/build.sh -type f -newer "$AGENT_SO" 2>/dev/null | head -1)" ] && return 0
  [ -n "$(find agent/java agent/kotlin agent/okhttp agent/okhttp-stubs agent/build-dex.sh -type f -newer "$AGENT_CAP" 2>/dev/null | head -1)" ] && return 0
  return 1   # up to date
}

if agent_needs_build; then
  if [ "${JACA_SKIP_AGENT:-0}" = 1 ]; then
    echo "⚠️  JACA_SKIP_AGENT=1 — skipping the in-process Android agent (agent network capture will be unavailable)."
  else
    echo "== building in-process Android agent (.so + dexes) =="
    if ! ( cd agent && ./build.sh && ./build-dex.sh ); then
      {
        echo ""
        echo "error: the in-process Android agent failed to build — the app would be incomplete"
        echo "       (agent mode is the default network-inspection path). Install the Android toolchain:"
        echo '         sdkmanager "ndk;27.2.12479018" "cmake;3.22.1" "platforms;android-36" "build-tools;34.0.0"'
        echo "         brew install kotlin"
        echo "       then re-run ./scripts/build.sh. To build the app WITHOUT the agent on purpose:"
        echo "         JACA_SKIP_AGENT=1 ./scripts/build.sh"
      } >&2
      exit 1
    fi
  fi
fi

# Bundle the agent into Resources/ so the app finds it inside its own bundle (works for the
# installed app too — no hardcoded source path). Copied before generating so it's part of the
# Resources build phase; cleared only when the build was deliberately run without the agent.
if [ -f "$AGENT_SO" ]; then
  cp -f "$AGENT_SO"   Resources/libsqueezeagent.so
  cp -f "$AGENT_BOOT" Resources/squeezeagent-boot.dex
  cp -f "$AGENT_CAP"  Resources/squeezeagent-capture.dex
  echo "✓ bundled in-process agent (arm64-v8a) into Resources/"
else
  rm -f Resources/libsqueezeagent.so Resources/squeezeagent-boot.dex Resources/squeezeagent-capture.dex
  echo "ℹ️  in-process agent not bundled (skipped) — agent mode will show build instructions in-app"
fi

# Always regenerate so the agent files (added/removed above) are reflected in the project.
xcodegen generate
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
