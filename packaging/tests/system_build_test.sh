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

# Build a system package with build_pkg.sh as callers do, with ROS_DISTRO and OS_VERSION set: a
# plain CMake library declaring <duatic_package_kind>system</duatic_package_kind>, in plain Ubuntu.
# Check its name, that it installs in /usr, and that a CMake project finds it with nothing
# sourced; then each refusal: a ROS image, another Ubuntu release, a ROS dependency whether from
# the public index or a private mapping, a kind tag it cannot read, and a name Ubuntu already has.
# Needs docker.
#
# Usage:  system_build_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'docker run --rm -v "$TMP:/t" ubuntu:24.04 sh -c "rm -rf /t/*" 2>/dev/null; rm -rf "$TMP"' EXIT

# The fixture: one header, one library, a CMake package config.
R="$TMP/repo/duatic_sys_fixture"
mkdir -p "$R/include/duatic_sys_fixture" "$R/src"
cat > "$R/package.xml" <<'XML'
<?xml version="1.0"?>
<package format="3">
  <name>duatic_sys_fixture</name>
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
printf 'int duatic_sys_fixture_answer();\n' > "$R/include/duatic_sys_fixture/answer.hpp"
printf '#include "duatic_sys_fixture/answer.hpp"\nint duatic_sys_fixture_answer() { return 42; }\n' > "$R/src/answer.cpp"
cat > "$R/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.22)
project(duatic_sys_fixture CXX)
include(GNUInstallDirs)
add_library(duatic_sys_fixture SHARED src/answer.cpp)
target_include_directories(duatic_sys_fixture PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include> $<INSTALL_INTERFACE:include>)
install(DIRECTORY include/ DESTINATION include)
install(TARGETS duatic_sys_fixture EXPORT duatic_sys_fixtureTargets LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})
install(EXPORT duatic_sys_fixtureTargets FILE duatic_sys_fixtureConfig.cmake NAMESPACE duatic_sys_fixture::
  DESTINATION share/duatic_sys_fixture/cmake)
CMAKE
printf 'BSD-3-Clause test licence\n' > "$TMP/repo/LICENSE"
printf 'Changelog\n=========\n\n1.2.3 (2026-11-07)\n------------------\n* First release\n' > "$R/CHANGELOG.rst"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" add .
git -C "$TMP/repo" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture

fail=0
ok() { echo "    ok    $1"; }
bad() { echo "    FAIL  $1"; fail=1; }

# variant <name> <sed expression on package.xml> [remove-changelog]: a commit of the fixture with
# its package.xml changed, cloned to $TMP/<name>.
variant() {
    rm -rf "${TMP:?}/$1"
    git clone -q "$TMP/repo" "$TMP/$1"
    [ -z "$2" ] || sed -i "$2" "$TMP/$1/duatic_sys_fixture/package.xml"
    [ -z "${3:-}" ] || rm "$TMP/$1/duatic_sys_fixture/CHANGELOG.rst"
    git -C "$TMP/$1" -c user.name=t -c user.email=t@example.invalid commit -q -am "$1" --allow-empty
}

# build <repo> <image> [docker args...]: build_pkg.sh for duatic_sys_fixture from $TMP/<repo> into
# $TMP/<repo>-out, as callers run it; prints the log.
build() {
    local repo="$1" image="$2"; shift 2
    mkdir -p "$TMP/$repo-out"
    docker run --rm -e ROS_DISTRO=jazzy -e OS_VERSION=noble "$@" \
        -v "$HERE/../builder:/builder:ro" -v "$TMP/$repo:/src" -v "$TMP/$repo-out:/out" \
        "$image" /builder/build_pkg.sh duatic_sys_fixture 2>&1 || true
}

# refused <description> <message> <repo> <image> [docker args...]: no .deb, and the log says why.
refused() {
    local desc="$1" msg="$2" repo="$3" log; shift 3
    log="$(build "$repo" "$@")"
    if ! ls "$TMP/$repo-out"/*.deb >/dev/null 2>&1 && printf '%s' "$log" | grep -qF -- "$msg"; then
        ok "$desc"
    else
        bad "$desc"; printf '%s\n' "$log" | tail -12 | sed 's/^/          /'
    fi
}

echo "--- building in ubuntu:24.04, with ROS_DISTRO=jazzy and OS_VERSION=noble set"
variant plain ""
log="$(build plain ubuntu:24.04)"
deb="$(ls "$TMP"/plain-out/duatic-sys-fixture_*.deb 2>/dev/null | head -n1 || true)"
if [ -n "$deb" ]; then ok "named duatic-sys-fixture, without a ROS prefix"; else bad "no duatic-sys-fixture .deb"; printf '%s\n' "$log" | tail -25; fi
if [ -n "$deb" ]; then
    info="$(docker run --rm -v "$TMP/plain-out:/out:ro" ubuntu:24.04 sh -c "dpkg-deb -I /out/$(basename "$deb"); dpkg-deb -c /out/$(basename "$deb")")"
    printf '%s' "$info" | grep -q ' ./usr/include/duatic_sys_fixture/answer.hpp$' && ok "installs in /usr" || bad "header not in /usr/include"
    printf '%s' "$info" | grep -q '/opt/' && bad "installs under /opt" || ok "nothing under /opt"
    printf '%s' "$info" | grep -q 'Duatic-Archive-Root: public' && ok "carries its archive root" || bad "no Duatic-Archive-Root"
    printf '%s' "$info" | grep -q 'Duatic-Package-Kind: system' && ok "declares itself a system package" || bad "no Duatic-Package-Kind"
    printf '%s' "$info" | grep -q 'Duatic-Vcs-Commit: [0-9a-f]\{40\}$' && ok "a clean commit" || bad "no clean Duatic-Vcs-Commit"
    printf '%s' "$info" | grep -q 'index.ros.org' && bad "a ROS index homepage" || ok "no ROS index homepage"
    printf '%s' "$info" | grep -E '^ Depends:' | grep -q 'ros-' && bad "depends on a ROS package" || ok "depends on no ROS package"
    if docker run --rm -v "$TMP/plain-out:/out:ro" ubuntu:24.04 bash -c '
        set -e; apt-get update -qq >/dev/null; apt-get install -y -qq cmake g++ >/dev/null 2>&1
        apt-get install -y -qq /out/duatic-sys-fixture_*.deb >/dev/null 2>&1
        mkdir /c && cd /c
        printf "cmake_minimum_required(VERSION 3.22)\nproject(c CXX)\nfind_package(duatic_sys_fixture REQUIRED)\nadd_executable(c c.cpp)\ntarget_link_libraries(c duatic_sys_fixture::duatic_sys_fixture)\n" > CMakeLists.txt
        printf "#include <duatic_sys_fixture/answer.hpp>\nint main() { return duatic_sys_fixture_answer() == 42 ? 0 : 1; }\n" > c.cpp
        cmake -S . -B b >/dev/null && cmake --build b >/dev/null && ./b/c' >/dev/null 2>&1; then
        ok "a plain CMake project finds and links it"
    else
        bad "a plain CMake project cannot use it"
    fi
fi

echo "--- generating its changelog"
variant nochangelog "" remove-changelog
log="$(build nochangelog ubuntu:24.04)"
ls "$TMP"/nochangelog-out/duatic-sys-fixture_*.deb >/dev/null 2>&1 && ok "builds with a generated changelog" \
    || { bad "no build with a generated changelog"; printf '%s\n' "$log" | tail -12; }

echo "--- refusals"
variant rosimage ""
refused "in a ROS image" "is a system package, built in a plain Ubuntu image; this one has ROS" rosimage ros:jazzy-ros-base
variant release ""
refused "for another Ubuntu release than the image's" "OS_VERSION=jammy, but the image is Ubuntu noble" release ubuntu:24.04 -e OS_VERSION=jammy

variant rclcpp 's|<buildtool_depend>cmake</buildtool_depend>|<buildtool_depend>cmake</buildtool_depend>\n  <depend>rclcpp</depend>|'
log="$(build rclcpp ubuntu:24.04)"
if ! ls "$TMP"/rclcpp-out/*.deb >/dev/null 2>&1 \
    && printf '%s' "$log" | grep -qE "Could not resolve rosdep key 'rclcpp'|it depends on ROS"; then
    ok "a dependency on ROS from the public index"
else
    bad "a dependency on ROS from the public index"; printf '%s\n' "$log" | tail -12
fi

variant private 's|<buildtool_depend>cmake</buildtool_depend>|<buildtool_depend>cmake</buildtool_depend>\n  <depend>ros_thing</depend>|'
mkdir -p "$TMP/rosdep"
printf 'ros_thing:\n  ubuntu:\n    noble: [ros-jazzy-ros-thing]\n' > "$TMP/rosdep/map.yaml"
refused "a dependency on ROS from a private mapping" "it depends on ROS" private ubuntu:24.04 \
    -v "$TMP/rosdep:/rosdep:ro" -e ROSDEP_YAML=/rosdep/map.yaml

variant split 's|<duatic_package_kind>system</duatic_package_kind>|<duatic_package_kind>\n      system\n    </duatic_package_kind>|'
refused "a kind tag over several lines" "is not on one line" split ubuntu:24.04

variant comment 's|<duatic_package_kind>system</duatic_package_kind>|<!-- <duatic_package_kind>system</duatic_package_kind> -->|'
refused "a kind tag in a comment" "remove the duatic_package_kind outside <export> or in a comment" comment ubuntu:24.04

variant shadowed 's|<duatic_package_kind>system</duatic_package_kind>|<!-- <duatic_package_kind>ros</duatic_package_kind> -->\n    <duatic_package_kind>system</duatic_package_kind>|'
refused "a commented ros tag before the real one" "reads as kind 'ros' here and 'system' in its <export>" \
    shadowed ros:jazzy-ros-base

# named <description> <name> <message>: the fixture renamed to <name> is refused, saying <message>.
named() {
    local log
    variant "$2" "s|<name>duatic_sys_fixture</name>|<name>$2</name>|"
    log="$(docker run --rm -e ROS_DISTRO=jazzy -v "$HERE/../builder:/builder:ro" -v "$TMP/$2:/src" \
        ubuntu:24.04 /builder/build_pkg.sh "$2" 2>&1 || true)"
    printf '%s' "$log" | grep -qF -- "$3" && ok "$1" || { bad "$1"; printf '%s\n' "$log" | tail -8; }
}
named "a name Ubuntu already has" hello "already has a package named hello"
named "a name that is a public rosdep key" eigen "is already a rosdep key in the public index"
named "a system package named ros-*" ros_thing "a system package is not named ros-*"
named "a name without a prefix builds" plain_lib "Done. Next: ./make_repo.sh"

echo
[ "$fail" = 0 ] && echo "all passed" || echo "FAILURES"
exit "$fail"
