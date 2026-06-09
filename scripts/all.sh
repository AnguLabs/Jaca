#!/usr/bin/env bash
# One-shot build of EVERYTHING: the Android in-process agent (.so + dexes), the
# macOS app, then launch it. The agent step is best-effort — if its toolchain
# (NDK/CMake/Kotlin) isn't installed, it's skipped with a warning and the app
# still builds (proxy capture works without the agent).
#
# Usage:
#   ./scripts/all.sh                 # build agent + app (Debug), then launch
#   ./scripts/all.sh --release       # optimized build
#   ./scripts/all.sh --install       # build Release + copy into /Applications + launch
#   ./scripts/all.sh --no-agent      # skip the agent build
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

# --- 1. Android agent (best-effort) ---------------------------------------
if [ "$DO_AGENT" = 1 ]; then
  step "Building Android agent (.so + dexes)"
  if ( cd agent && ./build.sh && ./build-dex.sh ); then
    echo "✓ agent artifacts -> agent/out/"
  else
    echo "⚠️  agent build skipped/failed — in-process capture won't be available."
    echo "    Proxy capture still works. To enable the agent, install:"
    echo "      sdkmanager \"ndk;27.2.12479018\" \"cmake;3.22.1\" \"platforms;android-36\""
    echo "      brew install kotlin"
  fi
fi

# --- 2. Generate + build the app ------------------------------------------
step "Generating Xcode project (XcodeGen)"
xcodegen generate >/dev/null
step "Building Jaca ($CONFIG)"
./scripts/build.sh "$CONFIG"

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Jaca-*/Build/Products/"$CONFIG"/Jaca.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "✗ could not locate the built Jaca.app"; exit 1; }
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
