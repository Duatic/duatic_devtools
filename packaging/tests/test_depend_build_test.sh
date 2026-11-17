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

# Build duatic_fixture_shared with build_pkg.sh and check that its tests take no part in the build:
# a test dependency apt cannot install does not stop it, and the tests are not configured.
# Needs docker.
#
# Usage:  test_depend_build_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker run --rm -i \
    -v "$HERE/../builder:/builder:ro" \
    -v "$HERE/fixtures:/fixtures:ro" \
    ros:jazzy-ros-base bash -s <<'INNER'
set -euo pipefail

# repo <dir> <test_depend element> <CMake added before ament_package()>: a repository holding
# duatic_fixture_shared under pkgs/, changed as given, committed.
repo() {
    local dir="$1" pkg="$1/pkgs/duatic_fixture_shared"
    mkdir -p "$dir/pkgs"
    cp -a /fixtures/duatic_fixture_shared "$dir/pkgs/"
    sed -i "s|  <export>|  $2\n\n  <export>|" "$pkg/package.xml"
    sed -i "s|^ament_package()|$3\nament_package()|" "$pkg/CMakeLists.txt"
    git -C "$dir" init -q
    git -C "$dir" add .
    git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
}

repo /repos/unavailable '<test_depend version_gte="99.0.0">ament_lint_auto</test_depend>' ''
repo /repos/configured '<test_depend>ament_lint_auto</test_depend>' \
    'if(BUILD_TESTING)\n  message(FATAL_ERROR "the tests are configured")\nendif()'

pass=0 fail=0
# check <name> <repository>: build_pkg.sh builds duatic_fixture_shared from <repository> into a
# .deb that still carries the package's files.
check() {
    local name="$1" repo="$2" got=built
    rm -r -f /src /out /tmp/deb
    cp -a "$repo" /src
    mkdir /out
    /builder/build_pkg.sh duatic_fixture_shared > /tmp/build.log 2>&1 < /dev/null || got=refused
    if [ "$got" = built ]; then
        dpkg-deb -x /out/*.deb /tmp/deb
        [ -f /tmp/deb/opt/ros/jazzy/share/duatic_fixture_shared/marker.txt ] || got="built without marker.txt"
    fi
    if [ "$got" = built ]; then
        pass=$((pass + 1)); echo "ok   $name"
    else
        fail=$((fail + 1)); echo "FAIL $name: $got"
        grep -v '^Skip distro' /tmp/build.log | tail -15
    fi
}

check "a test dependency apt cannot install does not stop the build" /repos/unavailable
check "the tests are not configured" /repos/configured

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
INNER
