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

# Two signed archives, one public and one private, with channels. Runs inside the container;
# see README.md for the docker command. Published to a directory, not a server.
#
# The signing key is a throwaway generated on first run.
#
# Usage:  /builder/publish.sh [stamp]

set -euo pipefail

ROS_DISTRO_TARGET="${ROS_DISTRO_TARGET:-${ROS_DISTRO:-jazzy}}"
OUT=/out                        # built packages
DIST=/dist                      # published archive trees, visible on the host
GPGDIR=/builder/gnupg             # throwaway keyring, persisted so the install test can verify
APTLYDIR=/builder/aptly           # aptly's own database: repos, snapshots, package pool
CONF=/tmp/aptly.conf

# aptly keeps all state in rootDir. The default is discarded when a --rm container exits, and
# promotion needs the earlier snapshots.
STAMP="${1:-$(date +%Y%m%d%H%M%S)}"
KEY_NAME="${KEY_NAME:-Archive Signing Key}"
KEY_EMAIL="${KEY_EMAIL:-apt@example.invalid}"

HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"
hand_back_ownership() {
    [ "$HOST_UID" = "0" ] && return 0
    chown -R "$HOST_UID:$HOST_GID" "$DIST" "$GPGDIR" "$APTLYDIR" 2>/dev/null || true
}
trap hand_back_ownership EXIT

echo "=============================================================="
echo " publishing two archives, snapshot stamp $STAMP"
echo "=============================================================="

echo "--- installing aptly and gnupg"
apt-get update -qq
apt-get install -y -qq --no-install-recommends aptly gnupg

# ---------------------------------------------------------------- signing key
export GNUPGHOME="$GPGDIR"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
if ! gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
    echo "--- generating a throwaway signing key"
    # RSA: gnupg's default here is a curve the build cannot create, and an archive key must be
    # verifiable by every apt client.
    gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: $KEY_NAME
Name-Email: $KEY_EMAIL
Expire-Date: 0
%commit
EOF
else
    echo "--- reusing the existing throwaway signing key"
fi
KEYID="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')"  # codespell:ignore
echo "    key: $KEYID"

# Public half in the binary form apt's Signed-By expects. Must be on a robot before any signed
# source is usable.
mkdir -p "$DIST"
gpg --export "$KEYID" > "$DIST/duatic-archive.gpg"

# ---------------------------------------------------------------- aptly config
mkdir -p "$DIST/public" "$DIST/private" "$APTLYDIR"
cat > "$CONF" <<EOF
{
  "rootDir": "$APTLYDIR",
  "FileSystemPublishEndpoints": {
    "public":  {"rootDir": "$DIST/public",  "linkMethod": "copy"},
    "private": {"rootDir": "$DIST/private", "linkMethod": "copy"}
  }
}
EOF

apt_ly() { aptly -config="$CONF" "$@"; }

# ---------------------------------------------------------------- repos
# Visibility is a property of the repo a package is added to. Stated explicitly here; a real
# pipeline derives it and defaults to private.
for r in duatic-public duatic-private; do
    apt_ly repo show "$r" >/dev/null 2>&1 || apt_ly repo create -distribution=noble -component=main "$r"
done

add_if_present() {
    local repo="$1"; shift
    local found=0
    for f in "$@"; do
        [ -f "$f" ] || continue
        echo "    $repo <- $(basename "$f")"
        apt_ly repo add "$repo" "$f" || echo "    !! aptly refused $(basename "$f")"
        found=1
    done
    [ "$found" = 1 ] || echo "    !! nothing to add to $repo"
}

echo "--- adding packages"
shopt -s nullglob
# Which package goes to which repository is the caller's decision, as space separated globs
# relative to $OUT. A .ddeb is the same format with a different extension, so both are matched.
for pat in ${PUBLIC_PACKAGES:-}; do
    add_if_present duatic-public "$OUT"/${pat}_*.deb
    add_if_present duatic-public "$OUT"/${pat}-dbgsym_*.ddeb
done
for pat in ${PRIVATE_PACKAGES:-}; do
    add_if_present duatic-private "$OUT"/${pat}_*.deb
    add_if_present duatic-private "$OUT"/${pat}-dbgsym_*.ddeb
done
[ -n "${PUBLIC_PACKAGES:-}${PRIVATE_PACKAGES:-}" ] \
    || echo "    nothing selected: set PUBLIC_PACKAGES and/or PRIVATE_PACKAGES" >&2
shopt -u nullglob

echo
echo "--- repo contents"
apt_ly repo show -with-packages duatic-public  | sed 's/^/    /'
apt_ly repo show -with-packages duatic-private | sed 's/^/    /'

# ---------------------------------------------------------------- snapshots
# Immutable. Everything downstream refers to these, never to the mutable repos.
echo
echo "--- snapshotting"
apt_ly snapshot create "pub-$STAMP"  from repo duatic-public
apt_ly snapshot create "priv-$STAMP" from repo duatic-private

# ---------------------------------------------------------------- publish
# Two channels off one snapshot: promotion moves a pointer, so stable is byte-for-byte nightly.
# Architectures present in the supplied packages, as a sorted comma list.
ARCHS="$(ls "$OUT"/*.deb "$OUT"/*.ddeb 2>/dev/null \
    | sed -E 's/.*_([a-z0-9]+)\.(deb|ddeb)$/\1/' | grep -vx all | sort -u | paste -sd, -)"
echo "--- architectures found in $OUT: ${ARCHS:-none}"

norm_archs() { tr -d ' ' | tr ',' '\n' | sort -u | paste -sd, -; }

publish_or_switch() {
    local endpoint="$1" dist="$2" snap="$3"
    local line existing
    line="$(apt_ly publish list 2>/dev/null | grep -F "filesystem:${endpoint}:./${dist} " || true)"
    existing="$(printf '%s' "$line" | sed -nE 's/.*\[([^]]*)\].*/\1/p' | norm_archs)"

    # publish switch keeps the publication's architecture list, so a new architecture yields a
    # tree with no index for it. Drop and republish when the set changes.
    if [ -n "$existing" ] && [ "$existing" != "$(printf '%s' "$ARCHS" | norm_archs)" ]; then
        echo "    architectures changed ($existing -> $ARCHS), dropping $endpoint $dist"
        apt_ly publish drop "$dist" "filesystem:${endpoint}:"
        line=""
    fi

    if [ -n "$line" ]; then
        echo "    switch $endpoint $dist -> $snap"
        apt_ly publish switch -gpg-key="$KEYID" -batch "$dist" "filesystem:${endpoint}:" "$snap"
    else
        echo "    publish $endpoint $dist -> $snap [$ARCHS]"
        apt_ly publish snapshot -gpg-key="$KEYID" -batch \
            -architectures="$ARCHS" -distribution="$dist" -component=main \
            "$snap" "filesystem:${endpoint}:"
    fi
}

echo
echo "--- publishing channels"
publish_or_switch public  noble-nightly "pub-$STAMP"
publish_or_switch private noble-nightly "priv-$STAMP"

echo
echo "=============================================================="
echo " published"
echo "=============================================================="
apt_ly publish list | sed 's/^/    /'
echo
echo "--- archive trees"
find "$DIST" -maxdepth 4 \( -name InRelease -o -name Release \) | sort | sed 's/^/    /'
echo
echo "Promote later with:  /builder/publish.sh $STAMP   (re-run switches the same snapshot)"
echo "Next: install_from_archive.sh, in a container that has never seen the source."
