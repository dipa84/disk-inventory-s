#!/bin/zsh
# Copyright (C) 2026 Riccardo Di Paola. SPDX-License-Identifier: GPL-3.0-or-later
# Creates, once per Mac, a self-signed code signing certificate in the login keychain, so that
# tools/build-app.sh can sign every build with the same identity and macOS keeps the privacy
# permissions (Full Disk Access, Desktop, Documents…) from one build to the next.
# No Apple developer account needed; the app can be shared only after re-signing with Developer ID.
#
# To remove it: Keychain Access › login › My Certificates › "Disk Inventory S - Riccardo Di Paola".
set -e
name="Disk Inventory S - Riccardo Di Paola"
if security find-identity -p codesigning | grep -q "\"$name\""; then
  echo "already there: $name"
  exit 0
fi
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$dir/key.pem" -out "$dir/cert.pem" \
  -subj "/CN=$name" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false" 2>/dev/null
pass=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$dir/key.pem" -in "$dir/cert.pem" -name "$name" -out "$dir/id.p12" -passout "pass:$pass"
# -T: codesign may use the key without asking
security import "$dir/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$pass" -T /usr/bin/codesign
echo "created: $name"
