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

# Check that publish_archives.sh publishes a system package's build for each Ubuntu release only into
# that release's suite: its name, unlike a ROS package's, does not fix the release. Needs docker.
#
# Usage:  system_suites_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'docker run --rm -v "$TMP:/t" ubuntu:24.04 rm -rf /t/work >/dev/null 2>&1; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/work/lists" "$TMP/work/out"
cp "$HERE/../archive/"*.sh "$TMP/work/"
printf '# root: public\nduatic-foo\nros-jazzy-bar\n' > "$TMP/work/lists/public-jazzy.txt"
printf '# root: public\nduatic-foo\n' > "$TMP/work/lists/public-humble.txt"

out="$(docker run --rm -v "$TMP/work:/work" ubuntu:24.04 bash -c '
    set -e
    mk() {
        d="/tmp/d/$1-$2"; mkdir -p "$d/DEBIAN"
        printf "Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@example.invalid>\nDescription: t\n" \
            "$1" "$2" > "$d/DEBIAN/control"
        dpkg-deb -b "$d" "/work/out/$1_$2_amd64.deb" >/dev/null
    }
    mk duatic-foo 1.0.0-0jammy; mk duatic-foo 1.0.0-0noble; mk duatic-foo 1.0.0-0resolute
    mk ros-jazzy-bar 2.0.0-0noble
    for os in noble:jazzy jammy:humble; do
        OS_VERSION="${os%:*}" LIST_DISTROS="${os#*:}" CHANNEL=stable PKGDIRS=/work/out DIST=/work/dist \
            ALLOW_THROWAWAY_KEY=1 /work/publish_archives.sh > "/tmp/log" 2>&1 || { tail -20 /tmp/log; exit 1; }
    done
    for os in noble jammy; do
        sed -n "s/^Version: /$os /p" "/work/dist/public/dists/$os-stable/main/binary-amd64/Packages"
    done' < /dev/null 2>&1)" || { printf '%s\n' "$out"; exit 1; }

fail=0
check() {  # check <description> <expected line>
    if printf '%s\n' "$out" | grep -qxF "$2"; then echo "    ok    $1"; else echo "    FAIL  $1"; fail=1; fi
}
reject() {  # reject <description> <unexpected line>
    if printf '%s\n' "$out" | grep -qxF "$2"; then echo "    FAIL  $1"; fail=1; else echo "    ok    $1"; fi
}
check "noble-stable has the noble build" "noble 1.0.0-0noble"
reject "  and not the jammy build" "noble 1.0.0-0jammy"
reject "  nor the resolute build" "noble 1.0.0-0resolute"
check "  and the ROS package" "noble 2.0.0-0noble"
check "jammy-stable has the jammy build" "jammy 1.0.0-0jammy"
reject "  and nothing else" "jammy 1.0.0-0resolute"

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
