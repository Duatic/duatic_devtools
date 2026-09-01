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

# Build every package in packages.txt, in an order computed from what they declare.
#
# Each successful build lands in staging/, which the next build mounts as an apt source: a
# package that build-depends on another cannot build until that one is installable.
#
# Nothing is committed or tagged. CHANGELOG.rst is written into the working tree.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"   # the packaging/ directory, not the repository root

# The build matrix is (ROS distro, Ubuntu release); one pair at a time here. The base image ties
# the two together, so a distro without its matching image builds against the wrong libc.
ROS_DISTRO_TARGET="${ROS_DISTRO_TARGET:-jazzy}"
OS_VERSION="${OS_VERSION:-noble}"
BUILD_IMAGE="${BUILD_IMAGE:-ros:${ROS_DISTRO_TARGET}-ros-base}"
ROSDEP_FILE="${ROSDEP_FILE:-rosdep-${ROS_DISTRO_TARGET}.yaml}"
[ -f "$PKG/archive/rosdep/$ROSDEP_FILE" ] || {
    echo "FATAL: no rosdep mapping at archive/rosdep/$ROSDEP_FILE" >&2
    echo "       run: ROS_DISTRO_TARGET=$ROS_DISTRO_TARGET OS_VERSION=$OS_VERSION ./gen_release_set.sh" >&2
    exit 1; }
echo "building for $ROS_DISTRO_TARGET on ubuntu $OS_VERSION, using $BUILD_IMAGE"
OUT="$PKG/archive/out"
STAGING="$HERE/staging"
mkdir -p "$OUT" "$STAGING"

# Topological order over the release set, from the <depend>/<build_depend> each package declares.
ORDER="$(python3 - "$HERE" <<'PY'
import sys, pathlib, xml.etree.ElementTree as ET
here = pathlib.Path(sys.argv[1])
wanted = set(here.joinpath('packages.txt').read_text().split())
deps, where = {}, {}
for px in (here / 'src').rglob('package.xml'):
    if '.git' in px.parts: continue
    try: r = ET.parse(px).getroot()
    except Exception: continue
    n = (r.findtext('name') or '').strip()
    if n not in wanted: continue
    d = set()
    # Build-time only: exec-only dependencies need not exist when this package compiles.
    for tag in ('depend', 'build_depend', 'buildtool_depend', 'build_export_depend'):
        for e in r.findall(tag):
            if e.text and e.text.strip() in wanted: d.add(e.text.strip())
    deps[n] = d
    where[n] = px.parent.relative_to(here / 'src').parts[0]
order, seen, marked = [], set(), set()
def visit(n, chain=()):
    if n in seen: return
    if n in marked:                      # a cycle would otherwise recurse forever
        print(f"# cycle: {' -> '.join(chain + (n,))}", file=sys.stderr); return
    marked.add(n)
    for d in sorted(deps.get(n, ())): visit(d, chain + (n,))
    marked.discard(n); seen.add(n); order.append(n)
for n in sorted(deps): visit(n)
print(' '.join(f"{n}:{where[n]}" for n in order))
PY
)"
[ -n "$ORDER" ] || { echo "FATAL: could not compute a build order" >&2; exit 1; }

built=0; failed=0; failures=""
for entry in $ORDER; do
    pkg="${entry%%:*}"; repo="${entry##*:}"
    printf '=== %-42s (%s)\n' "$pkg" "$repo"
    if docker run --rm -i \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -e ROSDEP_YAML="/rosdep/$ROSDEP_FILE" \
        -e ROS_DISTRO="$ROS_DISTRO_TARGET" \
        -e OS_VERSION="$OS_VERSION" \
        -v "$HERE/src/$repo:/src" \
        -v "$PKG/builder:/builder" \
        -v "$PKG/archive/rosdep:/rosdep" \
        -e LOCAL_REPO=/staging \
        -v "$STAGING:/staging" \
        -v "$OUT:/out" \
        "$BUILD_IMAGE" \
        /builder/build_pkg.sh "$pkg" < /dev/null > "/tmp/build_$pkg.log" 2>&1; then
        # Into staging so the next package can build against it. .ddeb too, since a *.deb glob
        # misses debug packages. Fixtures stay out; they belong to packaging/tests.
        for a in "$OUT"/*.deb "$OUT"/*.ddeb; do
            [ -f "$a" ] || continue
            case "$(basename "$a")" in *fixture*) continue ;; esac
            cp -f "$a" "$STAGING/"
        done
        echo "    ok"; built=$((built+1))
    else
        echo "    FAILED: /tmp/build_$pkg.log"; failed=$((failed+1)); failures="$failures $pkg"
    fi
done
echo
echo "  $built built, $failed failed"
[ -n "$failures" ] && echo "  failures:$failures"
# Non-zero when anything failed: this is called from CI, where a silent success is worse than a
# noisy failure.
[ "$failed" -eq 0 ]
