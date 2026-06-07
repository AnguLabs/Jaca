#!/usr/bin/env bash
# Build + deploy + attach the Squeeze agent to a debuggable app, for iteration.
# Usage: ./deploy.sh [package] [serial]
set -euo pipefail
cd "$(dirname "$0")"
PKG="${1:-com.teya.ac.dev}"
SERIAL="${2:-emulator-5554}"
SOCK="squeeze_agent"
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
A() { "$ADB" -s "$SERIAL" "$@"; }
CC="/data/data/$PKG/code_cache"
SO=out/arm64-v8a/libsqueezeagent.so
DEX=out/squeezeagent.dex

ABIS="arm64-v8a" ./build.sh >/dev/null
./build-dex.sh >/dev/null
echo "built."

A shell am force-stop "$PKG" || true
ACT=$(A shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null | tail -1 | tr -d '\r' || true)
A shell am start -n "$ACT" >/dev/null 2>&1 || true
PID=""
for i in $(seq 1 10); do
  PID=$(A shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)
  [ -n "$PID" ] && break
  sleep 1
done
echo "pid=$PID"
[ -n "$PID" ] || { echo "app didn't start"; exit 1; }

A shell mkdir -p /data/local/tmp/squeeze
A push "$SO" /data/local/tmp/squeeze/ >/dev/null
A push "$DEX" /data/local/tmp/squeeze/ >/dev/null
A shell run-as "$PKG" rm -f code_cache/libsqueezeagent.so code_cache/squeezeagent.dex || true
A shell "run-as $PKG sh -c 'cat > $CC/libsqueezeagent.so' < /data/local/tmp/squeeze/libsqueezeagent.so"
A shell "run-as $PKG sh -c 'cat > $CC/squeezeagent.dex' < /data/local/tmp/squeeze/squeezeagent.dex"
A shell run-as "$PKG" chmod 444 code_cache/squeezeagent.dex   # ART rejects writable dex
A logcat -c
A shell "cmd activity attach-agent $PID '$CC/libsqueezeagent.so=$CC/squeezeagent.dex,$SOCK'" >/dev/null 2>&1 || true
sleep 2
echo "=== agent log ==="
A logcat -d 2>/dev/null | grep -i SqueezeAgent | tail -10
