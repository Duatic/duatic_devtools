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

# Build duatic_fixture_shared with build_pkg.sh from a repository storing its marker.txt in Git LFS:
# cloned with the content fetched, with and without the LFS filter in its own config, and with only
# the pointers. Each build starts without git-lfs installed, as the ROS image does. Needs docker.
#
# Usage:  lfs_build_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker run --rm -i \
    -v "$HERE/../builder:/builder:ro" \
    -v "$HERE/fixtures:/fixtures:ro" \
    ros:jazzy-ros-base bash -s <<'INNER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends git-lfs >/dev/null
git lfs install >/dev/null

up=/repos/upstream
mkdir -p "$up"
cp -a /fixtures/duatic_fixture_shared "$up/"
echo "mesh data" > "$up/duatic_fixture_shared/marker.txt"
git -C "$up" init -q
git -C "$up" lfs track marker.txt >/dev/null
git -C "$up" add .
git -C "$up" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
sha="$(git -C "$up" rev-parse HEAD)"

git clone -q "$up" /repos/fetched
git clone -q "$up" /repos/fetched-config
git -C /repos/fetched-config lfs install --local >/dev/null
GIT_LFS_SKIP_SMUDGE=1 git clone -q "$up" /repos/pointers
git lfs uninstall >/dev/null

pass=0 fail=0
# check <name> <built|refused> <pattern> <repository>: build_pkg.sh for duatic_fixture_shared from
# <repository> ends as expected, with a line of its log, or the commit and marker.txt of the .deb it
# built, matching the pattern.
check() {
    local name="$1" expect="$2" pattern="$3" repo="$4" got=built
    apt-get purge -y -qq git-lfs >/dev/null 2>&1
    git config --system --remove-section filter.lfs 2>/dev/null || true
    rm -r -f /src /out /tmp/deb
    cp -a "$repo" /src
    mkdir /out
    /builder/build_pkg.sh duatic_fixture_shared > /tmp/build.log 2>&1 < /dev/null || got=refused
    if [ "$got" = built ]; then
        dpkg-deb -x /out/*.deb /tmp/deb
        echo "Built: $(dpkg-deb -f /out/*.deb Duatic-Vcs-Commit) $(head -n1 /tmp/deb/opt/ros/jazzy/share/duatic_fixture_shared/marker.txt)" >> /tmp/build.log
    fi
    if [ "$got" = "$expect" ] && grep -qE "$pattern" /tmp/build.log; then
        pass=$((pass + 1)); echo "ok   $name"
    else
        fail=$((fail + 1)); echo "FAIL $name: $got, expected $expect with '$pattern'"
        grep -v '^Skip distro' /tmp/build.log | tail -15
    fi
}

check "fetched content builds clean" built "^Built: $sha mesh data$" /repos/fetched
check "fetched content with the filter in its config builds clean" built "^Built: $sha mesh data$" \
    /repos/fetched-config
check "pointers in place of content are refused" refused "Git LFS pointers instead of their content" \
    /repos/pointers

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
INNER
