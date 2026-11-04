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

# Build duatic_fixture_shared with build_pkg.sh and check the license text its .deb carries: from a
# LICENSE at the repository root, from one in the package directory over the root's, and with none.
# Needs docker.
#
# Usage:  license_build_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker run --rm -i \
    -v "$HERE/../builder:/builder:ro" \
    -v "$HERE/fixtures:/fixtures:ro" \
    ros:jazzy-ros-base bash -s <<'INNER'
set -euo pipefail

# repo <dir> <root license text or empty> <package license text or empty>: a repository holding
# duatic_fixture_shared under pkgs/, committed.
repo() {
    local dir="$1"
    mkdir -p "$dir/pkgs"
    cp -a /fixtures/duatic_fixture_shared "$dir/pkgs/"
    if [ -n "$2" ]; then printf '%s\n' "$2" > "$dir/LICENSE"; fi
    if [ -n "$3" ]; then printf '%s\n' "$3" > "$dir/pkgs/duatic_fixture_shared/LICENSE"; fi
    git -C "$dir" init -q
    git -C "$dir" add .
    git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
}

repo /repos/root "Root license line one

Root license line three" ""
repo /repos/package "Root license" "Package license"
repo /repos/none "" ""

pass=0 fail=0
# check <name> <pattern> <repository>: build_pkg.sh for duatic_fixture_shared from <repository>
# builds, and its log followed by the copyright of the .deb matches the pattern.
check() {
    local name="$1" pattern="$2" repo="$3" got=built
    rm -r -f /src /out /tmp/deb
    cp -a "$repo" /src
    mkdir /out
    /builder/build_pkg.sh duatic_fixture_shared > /tmp/build.log 2>&1 < /dev/null || got=refused
    if [ "$got" = built ]; then
        dpkg-deb -x /out/*.deb /tmp/deb
        cat /tmp/deb/usr/share/doc/*/copyright >> /tmp/build.log
    fi
    if [ "$got" = built ] && grep -Pzq "$pattern" /tmp/build.log; then
        pass=$((pass + 1)); echo "ok   $name"
    else
        fail=$((fail + 1)); echo "FAIL $name: $got, expected built with '$pattern'"
        grep -v '^Skip distro' /tmp/build.log | tail -15
    fi
}

check "the root's license reaches the copyright" \
    "License: BSD-3-Clause\n Root license line one\n \.\n Root license line three\n" /repos/root
check "the package's license wins over the root's" "License: BSD-3-Clause\n Package license\n" /repos/package
check "without one the copyright keeps the stub, with a warning" \
    "WARNING: no LICENSE or COPYING(.|\n)*License: BSD-3-Clause\n See repository for full license text" \
    /repos/none

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
INNER
