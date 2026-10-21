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

# Check that add_and_publish.sh refuses an open root whose packages depend on gated ones. Needs
# dpkg-deb, and stubs docker so nothing is signed or published. See README.md for the docker command.
#
# Usage:  open_roots_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADD="$HERE/../archive/add_and_publish.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
printf '#!/bin/sh\n[ "$1" = run ] && touch "$ARCHIVE/published"\nexit 0\n' > "$TMP/bin/docker"
chmod +x "$TMP/bin/docker"

# archive <name>: start an empty archive for one case, with its builder output in $B.
archive() {
    A="$TMP/$1/archive"
    B="$TMP/$1/builder/out"
    mkdir -p "$A/out" "$A/lists" "$B"
    printf '#!/bin/sh\n' > "$A/publish_archives.sh"; chmod +x "$A/publish_archives.sh"
}

# deb <name> <root> [depends] [provides]: build a package declaring <root>, without routing it.
# VER sets its version and DIR where it is written. SOURCE=1 declares Duatic-Publish-Source and
# writes its source tarball.
deb() {
    local d="$TMP/build/$1"
    mkdir -p "$d/DEBIAN"
    {
        echo "Package: $1"; echo "Version: ${VER:-1.0}"; echo "Architecture: all"
        echo "Maintainer: test <test@example.invalid>"; echo "Description: test"
        echo "Duatic-Archive-Root: $2"
        [ -z "${3:-}" ] || echo "Depends: $3"
        [ -z "${4:-}" ] || echo "Provides: $4"
        [ -z "${SOURCE:-}" ] || echo "Duatic-Publish-Source: true"
    } > "$d/DEBIAN/control"
    dpkg-deb --build "$d" "${DIR:-$A/out}/${1}_${VER:-1.0}_all.deb" >/dev/null
    [ -z "${SOURCE:-}" ] || : > "${DIR:-$A/out}/${1}_${VER:-1.0}.src.tar.gz"
    rm -r "$d"
}

# pkg <name> <root> [depends] [provides]: build a package declaring <root> and route it there.
pkg() {
    local list
    deb "$@"
    list="$A/lists/$(printf '%s' "$2" | tr '/' '-')-test.txt"
    [ -f "$list" ] || printf '# root: %s\n' "$2" > "$list"
    echo "$1" >> "$list"
}

fail=0
# expect <pass|fail> <description> <spec> [message]: publish, and check whether it got past the
# dependency check and that it said [message]. A refusal must say why.
expect() {
    local out
    rm -f "$A/published"
    out="$(cd "$A" && PATH="$TMP/bin:$PATH" ARCHIVE="$A" DISTRO=test "$ADD" "$3" 2>&1)" || true
    if [ "$1" = pass ] && [ -f "$A/published" ] \
        && { [ -z "${4:-}" ] || printf '%s' "$out" | grep -qF -- "$4"; }; then
        echo "    ok    $2"
    elif [ "$1" = fail ] && [ ! -f "$A/published" ] && printf '%s' "$out" | grep -qF -- "$4"; then
        echo "    ok    $2"
    else
        echo "    FAIL  $2"; printf '%s\n' "$out" | sed 's/^/          /'; fail=1
    fi
}

# unlisted <description> <name>: check no routing list names <name>.
unlisted() {
    if grep -qxF "$2" "$A"/lists/*.txt; then
        echo "    FAIL  $1"; fail=1
    else
        echo "    ok    $1"
    fi
}

archive public-dep
pkg lib-open public
pkg app public lib-open
expect pass "open package depending on a public package" app:public:1.0

archive gated-dep
pkg lib-gated products/a
pkg app public "lib-gated (>= 1.0)"
expect fail "open package depending on a gated-only package" app:public:1.0 \
    "published only in gated roots: lib-gated in products/a"

archive alternative
pkg lib-gated products/a
pkg lib-open public
pkg app public "lib-gated | lib-open"
expect pass "alternative with one open option" app:public:1.0

archive external
pkg app public "libc6 (>= 2.34), python3:any"
expect pass "dependency outside the archive" app:public:1.0

archive open-roots
pkg lib-shared shared/open
pkg app public lib-shared
OPEN_ROOTS="other, shared/open" expect pass "dependency in a root named by OPEN_ROOTS" app:public:1.0
expect fail "the same dependency without OPEN_ROOTS" app:public:1.0 "lib-shared in shared/open"

archive open-roots-checked
pkg lib-gated products/a
pkg app shared/open lib-gated
OPEN_ROOTS=shared/open expect fail "package in an OPEN_ROOTS root depending on a gated one" \
    app:shared/open:1.0 "lib-gated in products/a"

archive whole-root
pkg lib-gated products/a
pkg stale public lib-gated
pkg app public
expect fail "an existing open package that now depends on a gated one" app:public:1.0 \
    "stale_1.0_all.deb in open root 'public'"

archive invalid
pkg app public
OPEN_ROOTS='bad;root' expect fail "an invalid OPEN_ROOTS entry" app:public:1.0 \
    "OPEN_ROOTS names an invalid root 'bad;root'"

archive refused-unwritten
pkg lib-gated products/a
deb app public lib-gated
deb other products/a
expect fail "a refused package" app:public:1.0 "lib-gated in products/a"
unlisted "a refused package is not routed" app
expect pass "a gated run after a refusal" other:products/a:1.0
unlisted "a gated run after a refusal does not route the refused package" app

archive gated-provider
pkg app public lib
deb lib products/a
expect fail "a gated package that an open one depends on" lib:products/a:1.0 \
    "app_1.0_all.deb in open root 'public'"
unlisted "a refused gated package is not routed" lib

archive provides-gated
pkg impl products/a "" virt
pkg app public virt
expect fail "a virtual package provided only by gated packages" app:public:1.0 \
    "virt in products/a"

archive provides-open
pkg impl products/a "" virt
pkg impl-open public "" "virt (= 1.0)"
pkg app public virt
expect pass "a virtual package with an open provider" app:public:1.0

archive other-distro
pkg lib-gated products/a
pkg app public lib-gated
printf '# root: public\nlib-gated\n' > "$A/lists/public-other.txt"
expect fail "a name public only in another distro's list" app:public:1.0 \
    "lib-gated in products/a"

archive builder-out
pkg lib-gated products/a
DIR="$B" pkg app public lib-gated
pkg other public
expect fail "a package found only in the builder output" other:public:1.0 \
    "app_1.0_all.deb in open root 'public'"

archive no-deb
pkg app public
printf 'missing\n' >> "$A/lists/public-test.txt"
expect pass "a listed package with no .deb" app:public:1.0 \
    "WARN: missing in open root public not checked: no .deb found"

archive stale
pkg lib-gated products/a
VER=0.9 pkg app public lib-gated
VER=1.1 deb app public
expect fail "a stale version depending on a gated package" app:public:1.1 \
    "A stale .deb is still published: remove it from out/."

# placed <description> <path>: check a source tarball was placed at <path> under the archive.
placed() {
    if [ -f "$A/$2" ]; then echo "    ok    $1"; else echo "    FAIL  $1"; fail=1; fi
}

# absent <description> <path>: check nothing was placed at <path> under the archive.
absent() {
    if [ -e "$A/$2" ]; then echo "    FAIL  $1"; fail=1; else echo "    ok    $1"; fi
}

archive sources
SOURCE=1 pkg app public
SOURCE=1 pkg lib-gated products/a
pkg plain public
expect pass "an open package declaring its source" app:public:1.0
placed "its source is placed in the open root" dist/public/sources/app/app_1.0.src.tar.gz
expect pass "a gated package declaring its source" lib-gated:products/a:1.0
absent "a gated package's source is not placed" dist/private/products/a/sources
expect pass "an open package that declares nothing" plain:public:1.0
absent "a package that declares nothing gets no source" dist/public/sources/plain

archive no-source
SOURCE=1 pkg app public
rm "$A/out/app_1.0.src.tar.gz"
expect fail "an open package declaring its source, without one" app:public:1.0 \
    "no out/app_1.0.src.tar.gz"

exit "$fail"
