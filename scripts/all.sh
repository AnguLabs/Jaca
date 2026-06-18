#!/usr/bin/env bash
# One-shot build of EVERYTHING: the macOS app + both in-process agents, then launch it.
# The Android agent (.so + dexes) and the iOS-Simulator agent are now built by build.sh
# itself (the agent is part of the product), so this script just adds the optional
# companion APK + install/launch convenience. A missing Android toolchain makes the
# build FAIL (the app would be incomplete) — pass --no-agent to opt out on purpose.
#
# Usage:
#   ./scripts/all.sh                 # build app + agents (Debug), then launch
#   ./scripts/all.sh --release       # optimized build
#   ./scripts/all.sh --install       # build Release + copy into /Applications + launch
#   ./scripts/all.sh --no-agent      # build the app WITHOUT the in-process Android agent
#   ./scripts/all.sh --no-run        # build only, don't launch
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG=Debug
DO_AGENT=1; DO_RUN=1; DO_INSTALL=0
for a in "$@"; do
  case "$a" in
    --release) CONFIG=Release ;;
    --debug)   CONFIG=Debug ;;
    --install) DO_INSTALL=1; CONFIG=Release ;;
    --no-agent) DO_AGENT=0 ;;
    --no-run)   DO_RUN=0 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)"; exit 1 ;;
  esac
done

step() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

# --- prerequisites ---------------------------------------------------------
command -v xcodegen >/dev/null 2>&1 || { echo "✗ xcodegen not found — run: brew install xcodegen"; exit 1; }
[ -d "$DEVELOPER_DIR" ] || { echo "✗ Xcode not found at $DEVELOPER_DIR (a full Xcode is required, not just CLT)"; exit 1; }

# --- 1. Android agent --------------------------------------------------------
# Built (when missing/stale) and bundled by build.sh below; --no-agent opts out via the
# same env var build.sh reads, so the build doesn't fail without the Android toolchain.
[ "$DO_AGENT" = 0 ] && export JACA_SKIP_AGENT=1

# --- 1b. Companion APK (install builds ship it inside the .app) ------------
# The bundled APK is what the installed app serves for QR onboarding, so build + bundle it
# before packaging the Release app. Best-effort — needs the Android toolchain (NDK/JDK).
if [ "$DO_INSTALL" = 1 ]; then
  step "Building companion APK (bundled into the app for QR onboarding)"
  if ./scripts/build-mobile.sh; then
    echo "✓ companion APK -> Resources/jaca-mobile.apk (bundled into the .app)"
  else
    echo "⚠️  companion APK build skipped/failed — installing with the APK already in Resources/ (if any)."
  fi
fi

# --- 2. Generate + build the app ------------------------------------------
step "Generating Xcode project (XcodeGen)"
xcodegen generate >/dev/null
step "Building Jaca ($CONFIG)"
./scripts/build.sh "$CONFIG"

# Resolve the build product for *this* project/config via showBuildSettings — not a
# `ls DerivedData/Jaca-*` glob: with multiple worktrees there are several Jaca-* derived
# data dirs, and `head -1` would grab the alphabetically-first (often a stale build),
# installing the wrong binary. (build.sh resolves it the same way.)
APP="$(xcodebuild -project Jaca.xcodeproj -scheme Jaca -configuration "$CONFIG" \
  -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')"
[ -n "$APP" ] && [ -d "$APP" ] || { echo "✗ could not locate the built Jaca.app"; exit 1; }
echo "✓ built: $APP"

# --- 3. Install (optional) -------------------------------------------------
if [ "$DO_INSTALL" = 1 ]; then
  step "Installing to /Applications"
  rm -rf /Applications/Jaca.app
  cp -R "$APP" /Applications/Jaca.app
  APP=/Applications/Jaca.app
  echo "✓ installed: $APP"
fi

# --- 4. Launch (optional) --------------------------------------------------
if [ "$DO_RUN" = 1 ]; then
  step "Launching Jaca"
  open "$APP"
fi

step "Done"
