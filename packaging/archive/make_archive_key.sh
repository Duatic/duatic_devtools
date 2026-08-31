#!/usr/bin/env bash
# Copyright 2026 Duatic AG
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that
# the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions, and
#    the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and
#    the following disclaimer in the documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or
#    promote products derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Create the archive signing key. Run once, on a machine that is not the publish host.
#
# Produces a certification-only primary key and a signing subkey. The publish host gets the subkey
# and can sign; it cannot certify, so a compromised host is handled by rotating the subkey rather
# than by reissuing the identity every robot has pinned.
#
# Usage:  ./make_archive_key.sh [output directory]
set -euo pipefail

OUT="${1:-$PWD/archive-key}"
UID_NAME="${KEY_NAME:?set KEY_NAME, the identity robots will see on the archive key}"
UID_EMAIL="${KEY_EMAIL:?set KEY_EMAIL}"
PRIMARY_EXPIRY="${PRIMARY_EXPIRY:-5y}"
SUBKEY_EXPIRY="${SUBKEY_EXPIRY:-2y}"

[ -e "$OUT" ] && { echo "FATAL: $OUT exists. Refusing to overwrite an archive key." >&2; exit 1; }

# The primary key must never be created where the archive is published from.
if [ -d /dist ] || [ -n "${CI:-}" ]; then
    echo "FATAL: this looks like a publish host or CI. Generate the key elsewhere." >&2
    exit 1
fi
command -v gpg >/dev/null || { echo "FATAL: gpg not installed" >&2; exit 1; }

# The key must have a passphrase. Normally pinentry asks; KEY_PASSPHRASE covers the case where
# there is no terminal, which is the only way to run this unattended.
GPG_ARGS=()
if [ -n "${KEY_PASSPHRASE:-}" ]; then
    GPG_ARGS=(--batch --pinentry-mode loopback --passphrase "$KEY_PASSPHRASE")
elif [ ! -t 0 ]; then
    echo "FATAL: no terminal to ask for a passphrase. Set KEY_PASSPHRASE or run interactively." >&2
    exit 1
fi

mkdir -p "$OUT"; chmod 700 "$OUT"
export GNUPGHOME="$OUT/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

echo "--- primary key, certification only"
gpg "${GPG_ARGS[@]}" --quick-generate-key "$UID_NAME <$UID_EMAIL>" rsa4096 cert "$PRIMARY_EXPIRY"
FPR="$(gpg --list-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"
[ -n "$FPR" ] || { echo "FATAL: no key generated" >&2; exit 1; }

echo "--- signing subkey"
gpg "${GPG_ARGS[@]}" --quick-add-key "$FPR" rsa4096 sign "$SUBKEY_EXPIRY"

echo "--- exporting"
# gpg writes a revocation certificate at creation. Move it out: it belongs apart from the key, and
# it is the only way to withdraw trust without reaching every robot.
cp "$GNUPGHOME/openpgp-revocs.d/$FPR.rev" "$OUT/revoke.asc"
# Binary, which is the form apt's Signed-By expects.
gpg --export "$FPR" > "$OUT/duatic-archive.gpg"
# The subkey alone. The primary stays here and goes to cold storage.
gpg "${GPG_ARGS[@]}" --export-secret-subkeys "$FPR" > "$OUT/signing-subkey.gpg"

for f in duatic-archive.gpg signing-subkey.gpg revoke.asc; do
    [ -s "$OUT/$f" ] || { echo "FATAL: $f is empty" >&2; exit 1; }
done

# An export that cannot be imported is worth discovering now rather than during an incident.
probe="$(mktemp -d)"
GNUPGHOME="$probe" gpg --import "$OUT/duatic-archive.gpg" >/dev/null 2>&1
GNUPGHOME="$probe" gpg --list-keys --with-colons | grep -q "$FPR" || {
    echo "FATAL: exported keyring does not contain $FPR" >&2; rm -r "$probe"; exit 1; }
rm -r "$probe"

chmod -R go-rwx "$OUT"

cat <<TXT

  fingerprint  $FPR

  $OUT/
    gnupg/               the primary key. Back up encrypted, two locations, then take it offline.
    revoke.asc           revocation certificate. Store apart from the key.
    duatic-archive.gpg   public half. Ships in the robot image as a keyring package.
    signing-subkey.gpg   for the publish host, and nowhere else.

  On the publish host:
    gpg --homedir <archive>/gnupg --import signing-subkey.gpg
    export EXPECTED_KEY_FPR=$FPR

  Both expiries are real deadlines: an expired key fails apt on every robot exactly as a lost one
  does. Put the subkey renewal on a calendar, or reissue with PRIMARY_EXPIRY=never.
TXT
