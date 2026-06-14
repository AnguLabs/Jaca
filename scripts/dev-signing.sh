#!/usr/bin/env bash
# One-time: create a stable, self-signed "Jaca Dev" code-signing identity so debug builds
# keep a FIXED code signature across rebuilds.
#
# Why: macOS binds a keychain item's "Always Allow" to the requesting app's code signature.
# Ad-hoc builds (CODE_SIGN_IDENTITY="-") get a new signature every rebuild, so "Always Allow"
# for the CA private key never sticks and you're re-prompted on every launch. With a stable
# identity you approve the prompt once and it holds.
#
# The identity lives in a DEDICATED keychain with a known password, so this is fully
# non-interactive and never touches your login keychain or its search list. build.sh re-signs
# the built .app with it automatically (and falls back to ad-hoc if this was never run).
# Idempotent. To undo: security delete-keychain "$HOME/Library/Keychains/jaca-dev.keychain-db"
set -euo pipefail

IDENTITY="Jaca Dev"
KC="$HOME/Library/Keychains/jaca-dev.keychain-db"
KC_PASS="jaca-dev"

if security find-identity -v -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "✓ '$IDENTITY' already set up in $KC"
  exit 0
fi

echo "==> Creating '$IDENTITY' code-signing identity (one-time, dedicated keychain)…"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KC"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cs.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = Jaca Dev
[ ext ]
basicConstraints = critical, CA:FALSE
keyUsage         = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# Use the system LibreSSL: its PKCS#12 output is readable by macOS `security import`,
# whereas Homebrew OpenSSL 3 writes a MAC algorithm the Security framework rejects.
SSL=/usr/bin/openssl
"$SSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cs.cnf" >/dev/null 2>&1
"$SSL" pkcs12 -export -name "$IDENTITY" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:jaca >/dev/null 2>&1

# Import and authorize codesign to use the key without prompting (known keychain password).
security import "$TMP/id.p12" -k "$KC" -P jaca -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null 2>&1 || true

# Trust the self-signed cert for code signing — the one step that needs your authorization
# (a macOS trust-settings prompt). codesign refuses an untrusted identity. After this,
# re-signing and the keychain "Always Allow" are non-interactive.
echo "==> Trusting the certificate for code signing — authorize the macOS prompt when it appears…"
security add-trusted-cert -r trustRoot -p codeSign "$TMP/cert.pem" || true

# Self-test: can codesign actually sign with it now?
PROBE="$TMP/probe"; cp /bin/echo "$PROBE"
if codesign --force --sign "$IDENTITY" --keychain "$KC" "$PROBE" >/dev/null 2>&1; then
  echo "✓ '$IDENTITY' is set up and usable."
  echo "  Next: ./scripts/build.sh re-signs with it; on first launch click \"Always Allow\" once and it sticks."
else
  echo "⚠ '$IDENTITY' was created but codesign can't use it yet (cert not trusted)."
  echo "  Trust it in Keychain Access: keychain 'jaca-dev' > 'Jaca Dev' > Get Info > Trust >"
  echo "  'Code Signing: Always Trust'. Then re-run ./scripts/build.sh."
  exit 1
fi
