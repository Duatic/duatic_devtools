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

# Check that publish_archives.sh builds a product line's setup package: in the line's suite of the
# public root and at the bootstrap path, with the same bytes on every publish, refused when its
# contents change without a new SETUP_VERSION, and good enough to install from. Needs docker.
#
# Usage:  setup_package_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'docker run --rm -v "$TMP:/t" ubuntu:24.04 rm -rf /t/work >/dev/null 2>&1; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work/lists" "$TMP/work/out"
cp "$HERE/../archive/"*.sh "$TMP/work/"
printf '# root: public\napp\n' > "$TMP/work/lists/public-jazzy.txt"
printf '# root: products/a\ngapp\n' > "$TMP/work/lists/products-a-jazzy.txt"

out="$(docker run --rm -v "$TMP/work:/work" ubuntu:24.04 bash -c '
    set -e
    mk() {
        d="/tmp/d/$1"; mkdir -p "$d/DEBIAN"
        printf "Package: %s\nVersion: 1.0.0-0noble\nArchitecture: amd64\nMaintainer: t <t@example.invalid>\nDescription: t\n" \
            "$1" > "$d/DEBIAN/control"
        dpkg-deb -b "$d" "/work/out/$1_1.0.0-0noble_amd64.deb" >/dev/null
    }
    mk app; mk gapp
    pub() {  # pub <channel> [VAR=value...]: publish noble-<channel>, printing FATAL lines on failure
        ch="$1"; shift
        env OS_VERSION=noble LIST_DISTROS=jazzy CHANNEL="$ch" PKGDIRS=/work/out DIST=/work/dist \
            ALLOW_THROWAWAY_KEY=1 SETUP_URL=file:///work/dist/public SETUP_NAME=example "$@" \
            /work/publish_archives.sh > /tmp/log 2>&1 && echo "published $ch" \
            || { echo "refused $ch"; grep FATAL /tmp/log; }
    }
    index() { awk "/^Package: example-/{p=\$2} /^Version:/{if(p){print p\"  \"\$2; p=\"\"}}" "$1"; }
    boot=/work/dist/public/setup/noble/example-product1-apt-source.deb
    pub product1
    echo "line: $(index /work/dist/public/dists/noble-product1/main/binary-amd64/Packages)"
    [ -f "$boot" ] && echo "bootstrap: $(dpkg-deb -f "$boot" Version)"
    [ -d /work/dist/private/products/a/setup ] && echo "gated root has a setup package" || echo "gated root: none"
    sum="$(sha256sum < "$boot")"
    pub product1
    [ "$(sha256sum < "$boot")" = "$sum" ] && echo "republish: same bytes"
    pub stable
    grep -q "^Package: example-" /work/dist/public/dists/noble-stable/main/binary-amd64/Packages \
        && echo "stable has a setup package" || echo "stable: none"
    pub product1 SETUP_URL=file:///elsewhere
    pub product1 SETUP_VERSION=2
    echo "bootstrap now: $(dpkg-deb -f "$boot" Version)"
    dpkg-deb -c "$boot" | awk "{print \$6}" | grep -v "/$"
    dpkg-deb --fsys-tarfile "$boot" | tar -xO ./etc/apt/sources.list.d/example-product1-apt-source.sources
' < /dev/null 2>&1)" || { printf '%s\n' "$out"; exit 1; }

# A fresh machine installs the bootstrap package, then the line's packages from the archive.
install="$(docker run --rm -v "$TMP/work:/work:ro" ubuntu:24.04 bash -c '
    set -e
    apt-get install -y -qq /work/dist/public/setup/noble/example-product1-apt-source.deb >/dev/null 2>&1
    apt-get update -qq 2>&1 | grep -i -E "err|warn" || true
    apt-get install -y -qq app >/dev/null 2>&1 && dpkg-query -W -f "installed \${Package} \${Version}\n" app example-product1-apt-source
' < /dev/null 2>&1)" || { printf '%s\n' "$install"; }

fail=0
check() {  # check <description> <expected line> <output>
    if printf '%s\n' "$3" | grep -qxF -- "$2"; then echo "    ok    $1"; else echo "    FAIL  $1"; fail=1; fi
}
check "a line publishes with its setup package" "published product1" "$out"
check "  in the line's suite" "line: example-product1-apt-source  1-0noble" "$out"
check "  and at the bootstrap path" "bootstrap: 1-0noble" "$out"
check "  not in a gated root" "gated root: none" "$out"
check "a republish gives the same bytes" "republish: same bytes" "$out"
check "a channel that is not a line gets none" "stable: none" "$out"
check "changed contents without a new version are refused" "refused product1" "$out"
check "  saying so" "FATAL: the example-product1-apt-source 1-0noble contents changed; raise SETUP_VERSION" "$out"
check "a new SETUP_VERSION takes them" "bootstrap now: 2-0noble" "$out"
check "  with the archive key" "./usr/share/keyrings/example-archive-keyring.gpg" "$out"
check "  and the line's suite as a source" "Suites: noble-product1" "$out"
check "a machine installs the line through it" "installed app 1.0.0-0noble" "$install"
check "  and keeps it installed" "installed example-product1-apt-source 2-0noble" "$install"

echo
[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; printf '%s\n' "$out" "$install" | sed 's/^/      /'; }
exit "$fail"
