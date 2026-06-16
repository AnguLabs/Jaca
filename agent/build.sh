#!/usr/bin/env bash
# Build the Squeeze native agent (.so) for the given ABIs using the Android NDK.
set -euo pipefail
cd "$(dirname "$0")"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="${ANDROID_NDK:-$ANDROID_HOME/ndk/27.2.12479018}"
CMAKE_BIN="$ANDROID_HOME/cmake/3.22.1/bin/cmake"
NINJA="$ANDROID_HOME/cmake/3.22.1/bin/ninja"
ABIS="${ABIS:-arm64-v8a}"   # Apple-Silicon devices + emulators share this ABI; that's all we ship
API="${API:-28}"

[ -x "$CMAKE_BIN" ] || CMAKE_BIN="$(command -v cmake)"
mkdir -p out

for ABI in $ABIS; do
  echo "== building $ABI =="
  "$CMAKE_BIN" -S native -B "build/$ABI" \
    -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API" >/dev/null
  "$CMAKE_BIN" --build "build/$ABI" >/dev/null
  mkdir -p "out/$ABI"
  cp "build/$ABI/libsqueezeagent.so" "out/$ABI/"
  echo "   -> out/$ABI/libsqueezeagent.so"
done
echo "done"
