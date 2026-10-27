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

# Check that archive_rosdep.sh maps exactly the dependencies the archive publishes.
#
# Usage:  archive_rosdep_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP="$HERE/../builder/archive_rosdep.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/package.xml" <<'XML'
<package format="3">
  <name>duatic_example</name>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <depend>soem_vendor</depend>
  <build_depend>duatic_headers</build_depend>
  <exec_depend>rclcpp</exec_depend>
  <test_depend>duatic_test_tools</test_depend>
</package>
XML
printf 'Package: ros-jazzy-soem-vendor\nVersion: 0.4.1-1noble\n\nPackage: ros-jazzy-duatic-headers\nVersion: 1.0.0-1noble\n' \
    > "$TMP/stable_Packages"
printf 'Package: ros-jazzy-duatic-test-tools\nVersion: 2.0.0+git20261027153012.ab12cd3-1noble\n' > "$TMP/edge_Packages"
printf 'Package: ros-kilted-soem-vendor\nVersion: 0.4.1-1noble\n' > "$TMP/kilted_Packages"
: > "$TMP/empty_Packages"

pass=0 fail=0
# check <name> <want> <args...>: archive_rosdep.sh with <args> prints <want>.
check() {
    local name="$1" want="$2"; shift 2
    local got
    got="$("$MAP" "$@" 2>&1)" || got="exit $? $got"
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1)); echo "ok   $name"
    else
        fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
    fi
}

check "maps what one index publishes" \
"duatic_headers:
  ubuntu:
    noble: [ros-jazzy-duatic-headers]
soem_vendor:
  ubuntu:
    noble: [ros-jazzy-soem-vendor]" \
    "$TMP/package.xml" jazzy noble "$TMP/stable_Packages"
check "maps across several indexes" \
"duatic_headers:
  ubuntu:
    noble: [ros-jazzy-duatic-headers]
duatic_test_tools:
  ubuntu:
    noble: [ros-jazzy-duatic-test-tools]
soem_vendor:
  ubuntu:
    noble: [ros-jazzy-soem-vendor]" \
    "$TMP/package.xml" jazzy noble "$TMP/stable_Packages" "$TMP/edge_Packages"
check "maps only the given distro's names" "{}" "$TMP/package.xml" jazzy noble "$TMP/kilted_Packages"
check "an empty index maps nothing" "{}" "$TMP/package.xml" jazzy noble "$TMP/empty_Packages"
check "needs an index" "exit 2 usage: archive_rosdep.sh <package.xml> <ros distro> <ubuntu release> <Packages file>..." \
    "$TMP/package.xml" jazzy noble

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
