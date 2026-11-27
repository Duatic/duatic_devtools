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

# Run workspace/build_all.sh over a throwaway workspace of fixtures, in four repositories:
# duatic_fixture_shared in the public root, duatic_fixture_unit_a in a gated root build-depending on
# it, duatic_fixture_unit_b in the public root that shared exec-depends on, and duatic_fixture_tools
# declaring no root. Real builds check the order, staging, versions,
# manifest and a stop at a failure; a stub docker checks what each build is given. Needs docker and
# python3 on the host.
#
# Usage:  build_all_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REV=202611260200
SHARED_V=0.1.0+git20261125223600.ab12cd3-${REV}noble
UNIT_V=0.1.0+git20261124101010.1234567-${REV}noble
RUNTIME_V=0.1.0+git20261124101010.fedcba9-${REV}noble
arch=amd64
[ "$(uname -m)" = aarch64 ] && arch=arm64

# repo <workspace> <repository> <fixture> [sed expression for package.xml]: the fixture in its own
# committed repository under src/.
repo() {
    local d="$1/packaging/workspace/src/$2"
    mkdir -p "$d"
    cp -a "$HERE/fixtures/$3" "$d/"
    [ -z "${4:-}" ] || sed -i "$4" "$d/$3/package.xml"
    GIT_CONFIG_GLOBAL=/dev/null git -C "$d" init -q
    GIT_CONFIG_GLOBAL=/dev/null git -C "$d" add .
    GIT_CONFIG_GLOBAL=/dev/null git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
}

# workspace <dir>: the packaging tooling and the four repositories, with the release set generated.
workspace() {
    local w="$1"
    mkdir -p "$w/packaging/workspace" "$w/packaging/archive"
    cp -a "$HERE/../builder" "$w/packaging/"
    cp "$HERE/../workspace/build_all.sh" "$HERE/../workspace/gen_release_set.sh" "$w/packaging/workspace/"
    repo "$w" base_repo duatic_fixture_shared \
        's|<duatic_archive_root>shared<|<duatic_archive_root>public<|; s|  <export>|  <exec_depend>duatic_fixture_unit_b</exec_depend>\n\n  <export>|'
    repo "$w" runtime_repo duatic_fixture_unit_b 's|units/unit-b|public|'
    repo "$w" unit_repo duatic_fixture_unit_a \
        's|  <export>|  <build_depend>duatic_fixture_shared</build_depend>\n\n  <export>|'
    repo "$w" tools_repo duatic_fixture_tools '/duatic_archive_root/d'
    printf '%s\n' "base_repo +git20261125223600.ab12cd3" "unit_repo +git20261124101010.1234567" \
        "tools_repo +git20261124101010.7654321" "runtime_repo +git20261124101010.fedcba9" > "$w/suffixes.txt"
    (cd "$w/packaging/workspace" && ./gen_release_set.sh > /dev/null)
}

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
no() { fail=$((fail + 1)); echo "FAIL $1"; }
# expect <name> <command...>: the command succeeds
expect() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

# ---------------------------------------------------------------- real builds, in order
w="$TMP/ordered"
workspace "$w"
out="$w/packaging/archive/out"
got=0
(cd "$w/packaging/workspace" && VERSION_SUFFIXES="$w/suffixes.txt" DEB_REVISION="$REV" ./build_all.sh) \
    > "$TMP/ordered.out" 2>&1 || got=$?
expect "the set builds" [ "$got" = 0 ]
[ "$got" = 0 ] || tail -30 "$TMP/ordered.out"
expect "the dependency builds before its dependent" python3 - "$TMP/ordered.out" <<'PY'
import sys
t = open(sys.argv[1]).read()
a, b = t.find("=== duatic_fixture_shared"), t.find("=== duatic_fixture_unit_a")
sys.exit(not (0 <= a < b))
PY
expect "a runtime dependency of a build dependency builds before the dependent" python3 - "$TMP/ordered.out" <<'PY'
import sys
t = open(sys.argv[1]).read()
c, a = t.find("=== duatic_fixture_unit_b"), t.find("=== duatic_fixture_unit_a")
sys.exit(not (0 <= c < a))
PY
shared_deb="$out/ros-jazzy-duatic-fixture-shared_${SHARED_V}_${arch}.deb"
unit_deb="$out/ros-jazzy-duatic-fixture-unit-a_${UNIT_V}_${arch}.deb"
expect "each package carries its repository's suffix and the revision" test -f "$shared_deb" -a -f "$unit_deb"
expect "the .deb versions are exact" [ "$(docker run --rm -v "$out:/out:ro" ros:jazzy-ros-base \
    sh -c "dpkg-deb -f '/out/${shared_deb##*/}' Version; dpkg-deb -f '/out/${unit_deb##*/}' Version" 2>/dev/null \
    | tr '\n' ' ')" = "$SHARED_V $UNIT_V " ]
expect "the dependent installs the dependency from staging" \
    grep -qF "Setting up ros-jazzy-duatic-fixture-shared ($SHARED_V)" "$out/logs/duatic_fixture_unit_a.log"
expect "each package keeps its log" test -s "$out/logs/duatic_fixture_shared.log"
expect "a package declaring no root is listed as skipped" grep -qE "skipped.*duatic_fixture_tools" "$TMP/ordered.out"
expect "a package declaring no root is not built" \
    test ! -e "$out/logs/duatic_fixture_tools.log" -a -z "$(find "$out" -name '*fixture-tools*')"
expect "the manifest lists every build with its root, files and seconds" \
    python3 - "$out" jazzy "$arch" "$SHARED_V" "$UNIT_V" "$RUNTIME_V" <<'PY'
import json, os, sys
out, distro, arch, sv, uv, rv = sys.argv[1:]
m = json.load(open(os.path.join(out, "manifest.json")))
want = {"duatic_fixture_unit_b": ("public", rv, "ros-jazzy-duatic-fixture-unit-b"),
        "duatic_fixture_shared": ("public", sv, "ros-jazzy-duatic-fixture-shared"),
        "duatic_fixture_unit_a": ("units/unit-a", uv, "ros-jazzy-duatic-fixture-unit-a")}
assert isinstance(m, list) and [e["package"] for e in m] == list(want), m
for e in m:
    root, v, deb = want[e["package"]]
    assert (e["root"], e["version"], e["distro"], e["arch"]) == (root, v, distro, arch), e
    assert f"{deb}_{v}_{arch}.deb" in e["files"], e
    assert all("/" not in f and os.path.isfile(os.path.join(out, f)) for f in e["files"]), e
    assert isinstance(e["seconds"], int) and e["seconds"] >= 0, e
PY

# ---------------------------------------------------------------- a failure stops the order
w="$TMP/failing"
workspace "$w"
out="$w/packaging/archive/out"
sed -i 's|^ament_package()|message(FATAL_ERROR "forced failure")\nament_package()|' \
    "$w/packaging/workspace/src/base_repo/duatic_fixture_shared/CMakeLists.txt"
got=0
(cd "$w/packaging/workspace" && VERSION_SUFFIXES="$w/suffixes.txt" DEB_REVISION="$REV" ./build_all.sh) \
    > "$TMP/failing.out" 2>&1 || got=$?
expect "a failed package fails the run" [ "$got" != 0 ]
expect "the run names the failed package and its log" \
    grep -qF "FAILED: $out/logs/duatic_fixture_shared.log" "$TMP/failing.out"
expect "the log holds the failure" grep -qF "forced failure" "$out/logs/duatic_fixture_shared.log"
expect "the dependent is not attempted" \
    test -z "$(grep -F '=== duatic_fixture_unit_a' "$TMP/failing.out")" -a ! -e "$out/logs/duatic_fixture_unit_a.log"

# ---------------------------------------------------------------- an invalid revision
got=0
docker run --rm -e DEB_REVISION=1a -v "$HERE/../builder:/builder:ro" -v "$HERE/fixtures:/src:ro" \
    ros:jazzy-ros-base /builder/build_pkg.sh duatic_fixture_shared > "$TMP/revision.out" 2>&1 < /dev/null || got=$?
expect "a revision that is not digits is refused" grep -qF "FATAL: DEB_REVISION" "$TMP/revision.out"

# ---------------------------------------------------------------- what each build is given
w="$TMP/stubbed"
workspace "$w"
repo "$w" extra_repo duatic_fixture_extra \
    's|  <export>|  <build_depend>duatic_fixture_unit_a</build_depend>\n\n  <export>|; s|extras/example|public|'
echo "extra_repo +git20261124101010.89abcde" >> "$w/suffixes.txt"
(cd "$w/packaging/workspace" && ./gen_release_set.sh > /dev/null)
out="$w/packaging/archive/out"
mkdir -p "$TMP/bin" "$TMP/args"
cat > "$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
pkg="${!#}" o="" prev=""
for a in "$@"; do
    [ "$prev" = -v ] && case "$a" in *:/out) o="${a%:/out}" ;; esac
    prev="$a"
done
printf '%s\n' "$@" > "$STUB_ARGS/$pkg"
case " ${STUB_FAIL:-} " in *" $pkg "*) exit 1 ;; esac
case " ${STUB_NODEB:-} " in *" $pkg "*) touch "$o/ros-jazzy-${pkg//_/-}-dbgsym_0.1.0-0noble_amd64.ddeb"; exit 0 ;; esac
touch "$o/ros-jazzy-${pkg//_/-}_0.1.0-0noble_amd64.deb"
STUB
chmod +x "$TMP/bin/docker"
touch "$TMP/keyring.gpg" "$TMP/client.crt" "$TMP/client.key"
public=https://archive.example.invalid/public
gated=https://gated.example.invalid/units/unit-a/
stubbed() {
    rm -f "$TMP/args"/*
    (cd "$w/packaging/workspace" && PATH="$TMP/bin:$PATH" STUB_ARGS="$TMP/args" VERSION_SUFFIXES="$w/suffixes.txt" \
        DEB_REVISION="$REV" ARCHIVE_URL="$public $gated" ARCHIVE_KEYRING="$TMP/keyring.gpg" \
        ARCHIVE_CLIENT_CERT="$TMP/client.crt" ARCHIVE_CLIENT_KEY="$TMP/client.key" env "$@" ./build_all.sh) \
        > "$TMP/stubbed.out" 2>&1
}
# given <package> <line>: the build of the package was given exactly this argument
given() { grep -qxF -- "$2" "$TMP/args/$1"; }
# withheld <package> <pattern>: no argument of the build matches the pattern
withheld() { ! grep -qE -- "$2" "$TMP/args/$1"; }

got=0; stubbed || got=$?
expect "the stubbed set builds" [ "$got" = 0 ]
expect "a build is given its repository's suffix" given duatic_fixture_unit_a "DEB_VERSION_SUFFIX=+git20261124101010.1234567"
expect "a build is given the revision" given duatic_fixture_shared "DEB_REVISION=$REV"
expect "the keyring is mounted read-only" given duatic_fixture_shared "$TMP/keyring.gpg:/archive/keyring.gpg:ro"
expect "the channels default to stable" given duatic_fixture_shared "ARCHIVE_CHANNELS=stable"
expect "a public package without gated dependencies reads only the open roots" \
    given duatic_fixture_shared "ARCHIVE_URL=$public"
expect "a public package without gated dependencies gets no client certificate" \
    withheld duatic_fixture_shared 'ARCHIVE_CLIENT|client\.(crt|key)'
expect "a package in a gated root reads every root" given duatic_fixture_unit_a "ARCHIVE_URL=$public $gated"
expect "a package in a gated root gets the client certificate, read-only" \
    given duatic_fixture_unit_a "$TMP/client.key:/archive/client.key:ro"
expect "a public package depending on a gated root reads only the open roots" \
    given duatic_fixture_extra "ARCHIVE_URL=$public"
expect "a public package depending on a gated root gets no client certificate" \
    withheld duatic_fixture_extra 'ARCHIVE_CLIENT|client\.(crt|key)'
expect "a package declaring no root is not handed to docker" test ! -e "$TMP/args/duatic_fixture_tools"
expect "a build's /out is inside the workspace" \
    grep -qE "^$w/packaging/workspace/\.work\.[^/]+/duatic_fixture_shared:/out\$" "$TMP/args/duatic_fixture_shared"
expect "the manifest lists the stubbed builds" python3 -c \
    'import json, sys; sys.exit([e["package"] for e in json.load(open(sys.argv[1]))] != ["duatic_fixture_unit_b", "duatic_fixture_shared", "duatic_fixture_unit_a", "duatic_fixture_extra"])' \
    "$out/manifest.json"

got=0; stubbed STUB_FAIL=duatic_fixture_shared STOP_ON_FAILURE=0 || got=$?
expect "with STOP_ON_FAILURE=0 the run goes on past a failure" test -e "$TMP/args/duatic_fixture_extra"
expect "with STOP_ON_FAILURE=0 a failure still fails the run" [ "$got" != 0 ]

echo '[{"package": "stale"}]' > "$out/manifest.json"
got=0; stubbed STUB_NODEB=duatic_fixture_shared || got=$?
expect "a build that hands back no .deb fails the run" test "$got" != 0
expect "and its log says so" grep -qF "no .deb reached" "$out/logs/duatic_fixture_shared.log"
expect "the manifest lists only what built before it" python3 -c \
    'import json, sys; sys.exit([e["package"] for e in json.load(open(sys.argv[1]))] != ["duatic_fixture_unit_b"])' \
    "$out/manifest.json"

echo '[{"package": "stale"}]' > "$out/manifest.json"
got=0; stubbed DEB_REVISION=1a || got=$?
expect "a revision that is not digits is refused before any build" \
    test "$got" != 0 -a -z "$(ls "$TMP/args")"
expect "the revision refusal says why" grep -qF "FATAL: DEB_REVISION" "$TMP/stubbed.out"
expect "a refused run leaves no stale manifest" test ! -e "$out/manifest.json"

sed -i '/^unit_repo /d' "$w/suffixes.txt"
got=0; stubbed || got=$?
expect "a repository missing from VERSION_SUFFIXES is refused before any build" \
    test "$got" != 0 -a -z "$(ls "$TMP/args")"
expect "the refusal names the repository" grep -qE "FATAL: .*unit_repo" "$TMP/stubbed.out"

# ---------------------------------------------------------------- a cycle through runtime dependencies
w="$TMP/cycle"
workspace "$w"
sed -i 's|  <export>|  <exec_depend>duatic_fixture_shared</exec_depend>\n\n  <export>|' \
    "$w/packaging/workspace/src/runtime_repo/duatic_fixture_unit_b/package.xml"
(cd "$w/packaging/workspace" && ./gen_release_set.sh > /dev/null)
rm -f "$TMP/args"/*
got=0
(cd "$w/packaging/workspace" && PATH="$TMP/bin:$PATH" STUB_ARGS="$TMP/args" VERSION_SUFFIXES="$w/suffixes.txt" \
    ./build_all.sh) > "$TMP/cycle.out" 2>&1 || got=$?
expect "a cycle through runtime dependencies still builds" [ "$got" = 0 ]
expect "a cycle through runtime dependencies is reported as one" \
    grep -qE "cycle through runtime dependencies: .*duatic_fixture_shared -> duatic_fixture_unit_b" "$TMP/cycle.out"

# ---------------------------------------------------------------- a routed package depending on an unrouted one
w="$TMP/unrouted"
workspace "$w"
unit_xml="$w/packaging/workspace/src/unit_repo/duatic_fixture_unit_a/package.xml"
sed -i 's|  <export>|  <exec_depend>duatic_fixture_tools</exec_depend>\n\n  <export>|' "$unit_xml"
(cd "$w/packaging/workspace" && ./gen_release_set.sh > /dev/null)
unrouted() {
    rm -f "$TMP/args"/*
    (cd "$w/packaging/workspace" && PATH="$TMP/bin:$PATH" STUB_ARGS="$TMP/args" VERSION_SUFFIXES="$w/suffixes.txt" \
        ./build_all.sh) > "$TMP/unrouted.out" 2>&1
}
got=0; unrouted || got=$?
expect "a routed package depending on an unrouted one is refused before any build" \
    test "$got" != 0 -a -z "$(ls "$TMP/args")"
expect "the refusal names the pair" \
    grep -qxF "  duatic_fixture_unit_a depends on duatic_fixture_tools" "$TMP/unrouted.out"
expect "the refusal says why" grep -qF "declares no <duatic_archive_root>" "$TMP/unrouted.out"
sed -i '/<exec_depend>duatic_fixture_tools</d' "$unit_xml"
(cd "$w/packaging/workspace" && ./gen_release_set.sh > /dev/null)
got=0; unrouted || got=$?
expect "without that dependency the set builds" [ "$got" = 0 ]

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
