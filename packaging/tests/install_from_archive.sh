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

# Install from the signed archives on a machine that has never seen the source. Runs inside the
# container; see README.md for the docker commands.
#
# No [trusted=yes]: the keyring is installed as it would be on a robot and every source is
# scoped to it with Signed-By.
#
# Usage (inside container):
#   /tests/install_from_archive.sh            both archives; the private package must install
#   /tests/install_from_archive.sh public     public archive only; it must NOT be installable

set -euo pipefail

DIST="${DIST:-/dist}"
MODE="${1:-both}"
DISTRO="${ROS_DISTRO:-jazzy}"
PKG="${PKG:?set PKG to the package that must install from the private archive}"
DEP="${DEP:-}"
KEYRING=/usr/share/keyrings/duatic-archive.gpg

[ -f "$DIST/duatic-archive.gpg" ] \
    || { echo "FATAL: no keyring at $DIST/duatic-archive.gpg. Run publish.sh first." >&2; exit 1; }

echo "=============================================================="
echo " installing from signed archives, mode: $MODE"
echo "=============================================================="

if [ -d /src ]; then
    echo "WARNING: /src is mounted, so this is not a clean machine."
else
    echo "--- clean machine: no source mounted"
fi

# ---------------------------------------------------------------- keyring first
# Cannot come from the archive: nothing signed verifies until it exists. On a robot it arrives
# in the provisioning image.
echo "--- installing the archive keyring"
install -m 0644 "$DIST/duatic-archive.gpg" "$KEYRING"

# ---------------------------------------------------------------- sources
# deb822 so Signed-By scopes this key to this archive; a globally trusted key validates any
# repository on the machine.
echo "--- writing sources (deb822, Signed-By scoped)"
cat > /etc/apt/sources.list.d/duatic-public.sources <<EOF
Types: deb
URIs: file:$DIST/public
Suites: noble-nightly
Components: main
Signed-By: $KEYRING
EOF

if [ "$MODE" = "both" ]; then
    cat > /etc/apt/sources.list.d/duatic-private.sources <<EOF
Types: deb
URIs: file:$DIST/private
Suites: noble-nightly
Components: main
Signed-By: $KEYRING
EOF
fi

ls -1 /etc/apt/sources.list.d/duatic-*.sources | sed 's/^/    /'

echo "--- apt-get update (signature verification happens here)"
apt-get update -qq

echo
echo "--- what apt can see"
if apt-cache policy "$PKG" | grep -q .; then
    apt-cache policy "$PKG" | sed 's/^/    /'
else
    echo "    $PKG is not visible to apt at all"
fi

if [ "$MODE" = "public" ]; then
    echo
    echo "--- negative test: the private package must NOT be installable"
    if apt-get install -y --dry-run "$PKG" >/dev/null 2>&1; then
        echo "FAIL: $PKG resolved with only the public archive configured." >&2
        echo "      Private packages are reachable without the private source." >&2
        exit 1
    fi
    echo "    correct: $PKG cannot be resolved from the public archive alone"
    echo
    echo "--- and the public package must still install fine"
    apt-get install -y "$DEP" >/dev/null
    echo "    $DEP installed from the public archive"
    echo
    echo "=============================================================="
    echo " PASS: the archives are genuinely separate."
    echo "=============================================================="
    exit 0
fi

echo
echo "--- installing $PKG (its dependency lives in the OTHER archive)"
apt-get install -y "$PKG"

echo
echo "--- which archive did each package come from?"
# The source line lives below "Version table", so print from there rather than a fixed range.
for p in "$PKG" "$DEP"; do
    printf '    %s\n' "$p"
    apt-cache policy "$p" | sed -n '/Version table/,$p' | grep -E 'file:|http' | sed 's/^ */      /'
done

echo
echo "--- every Duatic package installed"
dpkg-query -W -f='    ${Package} ${Version}\n' 'ros-*-duatic-*' 2>/dev/null || true

echo
echo "=============================================================="
echo " PASS: a private package installed and pulled its public"
echo "       dependency across archive boundaries, all signature"
echo "       verified with no trusted=yes anywhere."
echo "=============================================================="
