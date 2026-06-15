#!/usr/bin/env bash
# Probe what the companion VPN / MITM is letting through on the device, so you can see which
# traffic the decryption is breaking.
#
# Run it twice: once with capture ON (Start capture in the app) and once with capture OFF,
# and compare. A host that returns "HTTP 200 ssl=0" works. A host that fails with a non-zero
# ssl result, or times out, ONLY while capture is on is being broken by the MITM: that client
# does not trust the Jaca CA (most apps on Android 7+), or it pins its certificate. That is
# the app protecting itself, not a Jaca bug. Chrome and CA-trusting clients still work.
#
# Usage: scripts/companion-diag.sh [serial]
set -euo pipefail

ADB="$HOME/Library/Android/sdk/platform-tools/adb"
command -v adb >/dev/null 2>&1 && ADB="$(command -v adb)"
[ -x "$ADB" ] || { echo "adb not found"; exit 1; }

SERIAL="${1:-}"
[ -n "$SERIAL" ] || SERIAL="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
[ -n "$SERIAL" ] || { echo "No device connected. Plug one in or pass a serial."; exit 1; }
sh() { "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null | tr -d '\r'; }

echo "Device: $SERIAL"

echo; echo "== Capture VPN tunnel up? =="
if sh ip -o addr show | grep -q "tun"; then
  sh ip -o addr show | grep tun | sed 's/^/  /'
else
  echo "  no tun interface — capture is OFF"
fi

echo; echo "== Companion app running? =="
if [ -n "$(sh pidof dev.srsouza.jaca)" ]; then echo "  yes"; else echo "  no"; fi

echo; echo "== DNS =="
sh "ping -c1 -W2 google.com" | grep -E "bytes from|unknown host|100%" | head -1 | sed 's/^/  /' \
  || echo "  (ping unavailable)"

HAVE_CURL="$(sh 'command -v curl >/dev/null 2>&1 && echo yes || echo no')"
echo; echo "== HTTPS from the device (curl: $HAVE_CURL) =="
if [ "$HAVE_CURL" = "yes" ]; then
  for url in https://example.com https://www.google.com https://www.cloudflare.com \
             https://api.github.com https://www.apple.com; do
    res="$(sh "curl -sS -m 8 -o /dev/null -w 'HTTP %{http_code} ssl=%{ssl_verify_result}' $url 2>&1")"
    printf '  %-28s %s\n' "$url" "$res"
  done
  echo
  echo "  ssl=0 means the TLS cert validated (no MITM, or the CA is trusted by curl)."
  echo "  A non-zero ssl result or a timeout means the connection was intercepted and the"
  echo "  client refused the Jaca certificate. Compare with capture OFF to confirm."
else
  echo "  curl is not on this device. Test in Chrome (works) vs another app (may break) instead."
fi
