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

# Check product lines in add_and_publish.sh: what a line accepts, set releases from stable, and
# releases into stable patching the lines that hold the same X.Y. Needs dpkg-deb, and stubs docker
# with an index of what each channel would publish. See README.md for the docker command.
#
# Usage:  lines_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADD="$HERE/../archive/add_and_publish.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The stub publishes a channel as an index of the .debs in the out/ directory it is given.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'STUB'
#!/bin/bash
[ "$1" = run ] || exit 0
args=("$@")
ch=""; os=""; out=""; dist=""
while [ $# -gt 0 ]; do
    case "$1" in
        -e) case "$2" in CHANNEL=*) ch="${2#CHANNEL=}" ;; OS_VERSION=*) os="${2#OS_VERSION=}" ;; esac; shift ;;
        -v) case "$2" in *:/out) out="${2%:/out}" ;; *:/dist) dist="${2%:/dist}" ;; esac; shift ;;
    esac
    shift
done
printf '%s\n' "${args[@]}" > "$ARCHIVE/docker-args-$ch"
# STUB_FAIL names a channel whose publish fails, leaving its index as it was.
[ "${STUB_FAIL:-}" = "$ch" ] && exit 1
echo "$ch" >> "$ARCHIVE/published"
rm -rf "$dist/public/dists/$os-$ch"
mkdir -p "$dist/public/dists/$os-$ch/main/binary-all"
for deb in "$out"/*.deb; do
    [ -f "$deb" ] || continue
    printf 'Package: %s\nVersion: %s\n\n' "$(dpkg-deb -f "$deb" Package)" "$(dpkg-deb -f "$deb" Version)"
done > "$dist/public/dists/$os-$ch/main/binary-all/Packages"
STUB
chmod +x "$TMP/bin/docker"

# archive <name>: start an empty archive for one case.
archive() {
    A="$TMP/$1/archive"
    mkdir -p "$A/out/stable" "$A/lists" "$A/dist"
    printf '#!/bin/sh\n' > "$A/publish_archives.sh"; chmod +x "$A/publish_archives.sh"
    printf '# root: public\napp\nlib\n' > "$A/lists/public-test.txt"
}

# deb <version> <dir> [package]: build app, or <package>, at <version> into <dir> under the archive.
# ROOT sets the root it declares, public by default. EXTRAS=1 also writes its debug symbols and
# source tarball.
deb() {
    local name="${3:-app}" d="$TMP/build/pkg"
    mkdir -p "$d/DEBIAN" "$A/$2"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: test\nDuatic-Archive-Root: %s\n' \
        "$name" "$1" "${ROOT:-public}" > "$d/DEBIAN/control"
    dpkg-deb --build "$d" "$A/$2/${name}_${1}_all.deb" >/dev/null
    rm -r "$d"
    if [ -n "${EXTRAS:-}" ]; then
        : > "$A/$2/${name}-dbgsym_${1}_all.ddeb"
        : > "$A/$2/${name}_${1}.src.tar.gz"
    fi
}

fail=0
export OS_VERSION=noble
# run <pass|fail> <description> <spec> <message>: publish with CHANNEL and SET_RELEASE as set, and
# check the exit status and that the output says <message>.
run() {
    local out rc
    rm -f "$A/published"
    local specs=()
    read -r -a specs <<< "$3"
    out="$(cd "$A" && env PATH="$TMP/bin:$PATH" ARCHIVE="$A" DISTRO=test \
        CHANNEL="${CHANNEL:-stable}" SET_RELEASE="${SET_RELEASE:-0}" "$ADD" "${specs[@]}" 2>&1)" && rc=0 || rc=$?
    if { { [ "$1" = pass ] && [ "$rc" = 0 ]; } || { [ "$1" = fail ] && [ "$rc" != 0 ]; }; } \
        && printf '%s' "$out" | grep -qF -- "$4"; then
        echo "    ok    $2"
    else
        echo "    FAIL  $2 (exit $rc)"; printf '%s\n' "$out" | sed 's/^/          /'; fail=1
    fi
}

# check <description> <condition...>: a condition on the archive after a run.
check() {
    local desc="$1"; shift
    if (cd "$A" && "$@"); then echo "    ok    $desc"; else echo "    FAIL  $desc"; fail=1; fi
}

archive set-release
deb 2.0.0 out/stable
CHANNEL=product1 SET_RELEASE=1 run pass "a set release copies a release from stable into the line" app:public:2.0.0 \
    "ok    app 2.0.0 in dist/public/dists/noble-product1"
check "  the release stays in stable" test -f out/stable/app_2.0.0_all.deb
check "  and is in the line" test -f out/product1/app_2.0.0_all.deb

archive set-release-missing
CHANNEL=product1 SET_RELEASE=1 run fail "a set release of a version stable does not hold" app:public:2.0.0 \
    "app 2.0.0 is not in stable"

archive set-release-not-a-line
deb 2.0.0 out/stable
CHANNEL=stable SET_RELEASE=1 run fail "a set release into a channel that is not a line" app:public:2.0.0 \
    "SET_RELEASE takes a product line"

archive line-patch
deb 2.0.0 out/product1
deb 2.0.1 out
CHANNEL=product1 run pass "a line takes a patch of the X.Y it holds" app:public:2.0.1 \
    "ok    app 2.0.1 in dist/public/dists/noble-product1"

archive line-minor
deb 2.0.0 out/product1
deb 2.1.0 out
CHANNEL=product1 run fail "a line refuses a minor" app:public:2.1.0 "product1 holds no app 2.1.x"
check "  and leaves the delivery where it arrived" test -f out/app_2.1.0_all.deb

archive line-new-package
deb 1.0.0 out
CHANNEL=product1 run fail "a line refuses a package it does not hold" app:public:1.0.0 "product1 holds no app 1.0.x"

archive line-build-of-main
deb 2.0.0 out/product1
deb 2.0.1+git20261107120000.abc1234 out
CHANNEL=product1 run fail "a line refuses a build of main" app:public:2.0.1+git20261107120000.abc1234 \
    "the line product1 takes releases"

archive patch-flow
deb 2.0.0 out/product1
deb 2.0.0 out/stable
deb 2.0.2 out
run pass "a release into stable is published into the line holding its X.Y" app:public:2.0.2 \
    "ok    app 2.0.2 in dist/public/dists/noble-product1"
check "  stable published it too" grep -qx stable published
check "  the line has it" test -f out/product1/app_2.0.2_all.deb

archive patch-flow-minor
deb 2.0.0 out/product1
deb 2.1.0 out
run pass "a minor into stable" app:public:2.1.0 "ok    app 2.1.0 in dist/public/dists/noble-stable"
check "  does not reach the line" test ! -f out/product1/app_2.1.0_all.deb
check "  and the line is not republished" sh -c '! grep -qx product1 published'

archive patch-flow-two-lines
deb 1.4.0 out/product1
deb 2.0.0 out/product2
deb 2.0.1 out
run pass "a patch reaches only the line holding its X.Y" app:public:2.0.1 \
    "ok    app 2.0.1 in dist/public/dists/noble-product2"
check "  not the other" test ! -f out/product1/app_2.0.1_all.deb

archive line-older-patch
deb 2.0.3 out/product1
deb 2.0.1 out
CHANNEL=product1 run fail "a line refuses a patch older than one it holds" app:public:2.0.1 \
    "product1 holds no app 2.0.x older than 2.0.1"

archive line-suffix
deb 1.2~rc1 out/product1
deb 1.2.1 out
CHANNEL=product1 run pass "a line holding 1.2~rc1 takes 1.2.1" app:public:1.2.1 \
    "ok    app 1.2.1 in dist/public/dists/noble-product1"

archive bad-name
deb 2.0.0 out/stable
CHANNEL=product1 SET_RELEASE=1 run fail "a package name with a path in it" "a/../../app:public:2.0.0" \
    "is not a Debian package name"

archive set-release-partial
deb 2.0.0 out/stable
CHANNEL=product1 SET_RELEASE=1 run fail "a set release naming a version stable lacks" \
    "app:public:2.0.0 lib:public:1.0.0" "lib 1.0.0 is not in stable"
check "  copies nothing into the line" sh -c '! ls out/product1/*.deb 2>/dev/null'

archive set-release-refused-late
deb 2.0.0 out/stable
ROOT=products/a deb 1.0.0 out/stable lib
CHANNEL=product1 SET_RELEASE=1 run fail "a set release refused after copying" \
    "app:public:2.0.0 lib:public:1.0.0" "declares root 'products/a', asked to publish to 'public'"
check "  leaves the line as it was" sh -c '! ls out/product1/*.deb 2>/dev/null'

archive set-release-extras
EXTRAS=1 deb 2.0.0 out/stable
CHANNEL=product1 SET_RELEASE=1 run pass "a set release" app:public:2.0.0 "ok    app 2.0.0"
check "  copies the debug symbols" test -f out/product1/app-dbgsym_2.0.0_all.ddeb
check "  and the source" test -f out/product1/app_2.0.0.src.tar.gz

archive patch-flow-extras
deb 2.0.0 out/product1
EXTRAS=1 deb 2.0.1 out
run pass "a patch from stable" app:public:2.0.1 "ok    app 2.0.1 in dist/public/dists/noble-product1"
check "  brings its debug symbols to the line" test -f out/product1/app-dbgsym_2.0.1_all.ddeb
check "  and its source" test -f out/product1/app_2.0.1.src.tar.gz

archive docker-fails
deb 2.0.0 out
run pass "a first publish" app:public:2.0.0 "ok    app 2.0.0 in dist/public/dists/noble-stable"
cp "$A/out/stable/app_2.0.0_all.deb" "$A/out/"
STUB_FAIL=stable run fail "a failed publish of a version already indexed" app:public:2.0.0 "publishing noble-stable failed"

archive stable-fails
deb 2.0.0 out/product1
deb 2.0.1 out
STUB_FAIL=stable run fail "a release stable failed to publish" app:public:2.0.1 "publishing noble-stable failed"
check "  does not reach the line" test ! -f out/product1/app_2.0.1_all.deb

archive line-retry
deb 2.0.0 out/product1
deb 2.0.1 out
STUB_FAIL=product1 run fail "a line publish that fails" app:public:2.0.1 "publishing noble-product1 failed"
cp "$A/out/stable/app_2.0.1_all.deb" "$A/out/"
run pass "is repaired by a retry" app:public:2.0.1 "ok    app 2.0.1 in dist/public/dists/noble-product1"

archive edge
deb 1.0.0+git20261107120000.abc1234 out
CHANNEL=edge run pass "edge still publishes" app:public:1.0.0+git20261107120000.abc1234 \
    "ok    app 1.0.0+git20261107120000.abc1234 in dist/public/dists/noble-edge"
check "  and keeps its newest builds" grep -qx KEEP_VERSIONS=3 docker-args-edge

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
