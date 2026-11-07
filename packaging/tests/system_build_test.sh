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

# Build a system package with build_pkg.sh: a plain CMake library declaring
# <duatic_package_kind>system</duatic_package_kind>, in plain Ubuntu, then check its name, that it
# installs in /usr, and that a CMake project finds it with nothing sourced. Also check it is
# refused in a ROS image and when it depends on ROS. Needs docker.
#
# Usage:  system_build_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'docker run --rm -v "$TMP:/t" ubuntu:24.04 rm -rf /t/repo /t/out /t/out-ros /t/out-dep 2>/dev/null; rm -rf "$TMP"' EXIT

# The fixture: one header, one library, a CMake package config.
R="$TMP/repo/sys_fixture"
mkdir -p "$R/include/sys_fixture" "$R/src"
cat > "$R/package.xml" <<'XML'
<?xml version="1.0"?>
<package format="3">
  <name>sys_fixture</name>
  <version>1.2.3</version>
  <description>A library that needs no ROS</description>
  <maintainer email="test@example.invalid">test</maintainer>
  <license>BSD-3-Clause</license>
  <buildtool_depend>cmake</buildtool_depend>
  <export>
    <build_type>cmake</build_type>
    <duatic_package_kind>system</duatic_package_kind>
    <duatic_archive_root>public</duatic_archive_root>
  </export>
</package>
XML
printf 'int sys_fixture_answer();\n' > "$R/include/sys_fixture/answer.hpp"
printf '#include "sys_fixture/answer.hpp"\nint sys_fixture_answer() { return 42; }\n' > "$R/src/answer.cpp"
cat > "$R/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.22)
project(sys_fixture CXX)
include(GNUInstallDirs)
add_library(sys_fixture SHARED src/answer.cpp)
target_include_directories(sys_fixture PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include> $<INSTALL_INTERFACE:include>)
install(DIRECTORY include/ DESTINATION include)
install(TARGETS sys_fixture EXPORT sys_fixtureTargets LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(EXPORT sys_fixtureTargets FILE sys_fixtureConfig.cmake NAMESPACE sys_fixture::
  DESTINATION share/sys_fixture/cmake)
CMAKE
printf 'BSD-3-Clause test licence\n' > "$TMP/repo/LICENSE"
printf 'Changelog\n=========\n\n1.2.3 (2026-11-07)\n------------------\n* First release\n' > "$R/CHANGELOG.rst"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" add .
git -C "$TMP/repo" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture

fail=0
ok() { echo "    ok    $1"; }
bad() { echo "    FAIL  $1"; fail=1; }

# build <image> <out dir>: build_pkg.sh for sys_fixture in <image>; prints the log.
build() {
    mkdir -p "$TMP/$2"
    docker run --rm -v "$HERE/../builder:/builder:ro" -v "$TMP/repo:/src" -v "$TMP/$2:/out" \
        "$1" /builder/build_pkg.sh sys_fixture 2>&1 || true
}

echo "--- building in ubuntu:24.04"
log="$(build ubuntu:24.04 out)"
deb="$(ls "$TMP"/out/sys-fixture_*.deb 2>/dev/null | head -n1 || true)"
if [ -n "$deb" ]; then ok "named sys-fixture, without a ROS prefix"; else bad "no sys-fixture .deb"; printf '%s\n' "$log" | tail -25; fi
if [ -n "$deb" ]; then
    info="$(docker run --rm -v "$TMP/out:/out:ro" ubuntu:24.04 sh -c "dpkg-deb -I /out/$(basename "$deb"); dpkg-deb -c /out/$(basename "$deb")")"
    printf '%s' "$info" | grep -q ' ./usr/include/sys_fixture/answer.hpp$' && ok "installs in /usr" || bad "header not in /usr/include"
    printf '%s' "$info" | grep -q '/opt/' && bad "installs under /opt" || ok "nothing under /opt"
    printf '%s' "$info" | grep -q 'Duatic-Archive-Root: public' && ok "carries its archive root" || bad "no Duatic-Archive-Root"
    printf '%s' "$info" | grep -q 'Duatic-Vcs-Commit: [0-9a-f]\{40\}$' && ok "a clean commit" || bad "no clean Duatic-Vcs-Commit"
    printf '%s' "$info" | grep -q 'index.ros.org' && bad "a ROS index homepage" || ok "no ROS index homepage"
    printf '%s' "$info" | grep -E '^ Depends:' | grep -q 'ros-' && bad "depends on a ROS package" || ok "depends on no ROS package"
    # A plain CMake project finds it with nothing sourced.
    if docker run --rm -v "$TMP/out:/out:ro" ubuntu:24.04 bash -c '
        set -e; apt-get update -qq >/dev/null; apt-get install -y -qq cmake g++ >/dev/null 2>&1
        apt-get install -y -qq /out/sys-fixture_*.deb >/dev/null 2>&1
        mkdir /c && cd /c
        printf "cmake_minimum_required(VERSION 3.22)\nproject(c CXX)\nfind_package(sys_fixture REQUIRED)\nadd_executable(c c.cpp)\ntarget_link_libraries(c sys_fixture::sys_fixture)\n" > CMakeLists.txt
        printf "#include <sys_fixture/answer.hpp>\nint main() { return sys_fixture_answer() == 42 ? 0 : 1; }\n" > c.cpp
        cmake -S . -B b >/dev/null && cmake --build b >/dev/null && ./b/c' >/dev/null 2>&1; then
        ok "a plain CMake project finds and links it"
    else
        bad "a plain CMake project cannot use it"
    fi
fi

echo "--- refused in a ROS image"
log="$(build ros:jazzy-ros-base out-ros)"
printf '%s' "$log" | grep -q "is a system package, built in a plain Ubuntu image" && ok "refused in a ROS image" || bad "built in a ROS image"

echo "--- refused with a ROS dependency"
sed -i 's|<buildtool_depend>cmake</buildtool_depend>|<buildtool_depend>cmake</buildtool_depend>\n  <depend>rclcpp</depend>|' "$R/package.xml"
git -C "$TMP/repo" -c user.name=t -c user.email=t@example.invalid commit -q -am "depend on rclcpp"
log="$(build ubuntu:24.04 out-dep)"
if ! ls "$TMP"/out-dep/*.deb >/dev/null 2>&1 && printf '%s' "$log" | grep -qi "rclcpp"; then
    ok "refused when it depends on ROS"
else
    bad "built while depending on rclcpp"; printf '%s\n' "$log" | tail -10
fi

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
