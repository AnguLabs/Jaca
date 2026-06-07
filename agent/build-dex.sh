#!/usr/bin/env bash
# Compile the Java agent and dex it into out/squeezeagent.dex.
set -euo pipefail
cd "$(dirname "$0")"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_JAR="$ANDROID_HOME/platforms/android-36/android.jar"
D8="$(ls "$ANDROID_HOME"/build-tools/*/d8 | sort -V | tail -1)"

rm -rf classes && mkdir -p classes out
echo "== javac =="
find java -name "*.java" > /tmp/squeeze_agent_srcs.txt
javac --release 11 -cp "$ANDROID_JAR" -d classes @/tmp/squeeze_agent_srcs.txt

echo "== d8 =="
CLASSES=$(find classes -name "*.class")
"$D8" --min-api 28 --lib "$ANDROID_JAR" --output out $CLASSES
mv out/classes.dex out/squeezeagent.dex
echo "   -> out/squeezeagent.dex"
