#!/usr/bin/env bash
# Build two dexes:
#   out/squeezeagent-boot.dex     — Java trampoline (bootstrap class loader)
#   out/squeezeagent-capture.dex  — Kotlin capture + bundled kotlin-stdlib (isolated loader)
set -euo pipefail
cd "$(dirname "$0")"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ANDROID_JAR="$ANDROID_HOME/platforms/android-36/android.jar"
D8="$(ls "$ANDROID_HOME"/build-tools/*/d8 | sort -V | tail -1)"
KOTLIN_STDLIB="$(ls /opt/homebrew/opt/kotlin/libexec/lib/kotlin-stdlib.jar)"

rm -rf classes-boot classes-capture classes-okhttp-stubs && mkdir -p classes-boot classes-capture classes-okhttp-stubs out

echo "== boot dex (javac) =="
javac --release 11 -cp "$ANDROID_JAR" -d classes-boot $(find java -name '*.java')
"$D8" --min-api 28 --lib "$ANDROID_JAR" --output out $(find classes-boot -name '*.class')
mv out/classes.dex out/squeezeagent-boot.dex
echo "   -> out/squeezeagent-boot.dex"

echo "== capture dex (kotlinc + stdlib + okhttp3 interceptor) =="
kotlinc -nowarn -jvm-target 11 -classpath "$ANDROID_JAR:classes-boot" -d classes-capture $(find kotlin -name '*.kt')
# okhttp stubs are COMPILE-ONLY (the app provides the real okhttp3 at runtime); never bundled.
# SqueezeOkHttp3Interceptor.class IS bundled (into classes-capture) so the on-device child loader
# finds it alongside the rest of the capture dex.
javac --release 11 -d classes-okhttp-stubs $(find okhttp-stubs -name '*.java')
javac --release 11 -cp "$ANDROID_JAR:classes-boot:classes-okhttp-stubs" -d classes-capture $(find okhttp -name '*.java')
"$D8" --min-api 28 --lib "$ANDROID_JAR" --output out \
  $(find classes-capture -name '*.class') "$KOTLIN_STDLIB"
mv out/classes.dex out/squeezeagent-capture.dex
echo "   -> out/squeezeagent-capture.dex"
