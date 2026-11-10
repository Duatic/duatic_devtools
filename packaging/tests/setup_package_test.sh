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
# public root and at the bootstrap path, reused while unchanged, refused when its contents change
# without a new SETUP_VERSION or the version goes back, and good enough to install from. Needs docker.
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
printf '# root: public\napp\n' > "$TMP/work/lists/public-humble.txt"

out="$(docker run --rm -v "$TMP/work:/work" ubuntu:24.04 bash -c '
    set -e
    mk() {  # mk <package> [ubuntu]
        d="/tmp/d/$1-${2:-noble}"; mkdir -p "$d/DEBIAN"
        printf "Package: %s\nVersion: 1.0.0-0%s\nArchitecture: amd64\nMaintainer: t <t@example.invalid>\nDescription: t\n" \
            "$1" "${2:-noble}" > "$d/DEBIAN/control"
        dpkg-deb -b "$d" "/work/out/$1_1.0.0-0${2:-noble}_amd64.deb" >/dev/null
    }
    mk app; mk gapp; mk app jammy
    pub() {  # pub <channel> [VAR=value...]: write setup.conf from the defaults and VARs, publish noble-<channel>
        ch="$1"; shift
        conf="SETUP_URL=file:///work/dist/public SETUP_NAME=example SETUP_VERSION=1 $*"
        : > /work/setup.conf
        for kv in $conf; do printf "%s\n" "$kv" >> /work/setup.conf; done
        env OS_VERSION="${OSV:-noble}" LIST_DISTROS="${LD:-jazzy}" CHANNEL="$ch" PKGDIRS=/work/out DIST=/work/dist \
            ALLOW_THROWAWAY_KEY=1 /work/publish_archives.sh > /tmp/log 2>&1 && echo "published $ch" \
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
    gated=/work/dist/private/products/a/dists/noble-product1/InRelease
    gsum="$(sha256sum < "$gated")"
    pub product1 SETUP_URL=file:///elsewhere
    [ "$(sha256sum < "$gated")" = "$gsum" ] && echo "gated root after a refusal: unchanged"
    echo "after a refusal: $(dpkg-deb -f "$boot" Version) $( [ "$(sha256sum < "$boot")" = "$sum" ] && echo unchanged)"
    pub product1 SETUP_VERSION=2
    echo "bootstrap now: $(dpkg-deb -f "$boot" Version)"
    pub product1 SETUP_VERSION=1
    pub product2
    OSV=jammy LD=humble pub product1
    echo "jammy bootstrap: $(dpkg-deb -f /work/dist/public/setup/jammy/example-product1-apt-source.deb Version)"
    dpkg-deb -c "$boot" | awk "{print \$6}" | grep -v "/$"
    dpkg-deb --fsys-tarfile "$boot" | tar -xO ./etc/apt/sources.list.d/example-product1-apt-source.sources
' < /dev/null 2>&1)" || { printf '%s\n' "$out"; exit 1; }

# A fresh machine installs the bootstrap package, then the line's packages from the archive.
install="$(docker run --rm -v "$TMP/work:/work:ro" ubuntu:24.04 bash -c '
    set -e
    apt-get install -y -qq /work/dist/public/setup/noble/example-product1-apt-source.deb >/dev/null 2>&1
    apt-get install -y -qq /work/dist/public/setup/noble/example-product2-apt-source.deb >/dev/null 2>&1 \
        && echo "two lines side by side"
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
check "  saying so" "FATAL: the example-product1-apt-source 1-0noble contents changed; raise SETUP_VERSION in setup.conf" "$out"
check "  and leave the bootstrap as published" "after a refusal: 1-0noble unchanged" "$out"
check "  and every other root as it was" "gated root after a refusal: unchanged" "$out"
check "a new SETUP_VERSION takes them" "bootstrap now: 2-0noble" "$out"
check "an older SETUP_VERSION is refused" "FATAL: the archive holds example-product1-apt-source 2-0noble, newer than SETUP_VERSION gives (1-0noble)" "$out"
check "  with the archive key, named for the package" "./usr/share/keyrings/example-product1-apt-source.gpg" "$out"
check "another line publishes its own" "published product2" "$out"
check "another Ubuntu release gets its own version" "jammy bootstrap: 1-0jammy" "$out"
check "  and the line's suite as a source" "Suites: noble-product1" "$out"
check "a machine installs two lines' setup packages side by side" "two lines side by side" "$install"
check "a machine installs the line through it" "installed app 1.0.0-0noble" "$install"
check "  and keeps it installed" "installed example-product1-apt-source 2-0noble" "$install"

echo
[ "$fail" = 0 ] && echo "all passed" || { echo "FAILURES"; printf '%s\n' "$out" "$install" | sed 's/^/      /'; }
exit "$fail"
