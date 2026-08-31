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

# One ROS package -> one .deb. Runs inside the container; see README.md for the docker command.
#
# CHANGELOG.rst is written back to the mounted repo. The build uses a scratch copy so debian/
# and the .deb never land in git.
#
# Usage:  /builder/build_pkg.sh <ros package name>

set -euo pipefail

PKG="${1:?usage: build_pkg.sh <package_name>}"
SRC=/src            # the repository, mounted read-write
OUT=/out            # where .debs are copied out to
BUILD=/tmp/build
ROS_DISTRO_ARG="${ROS_DISTRO:-jazzy}"
OS_VERSION="${OS_VERSION:-noble}"

# Runs as root against a bind mount, so writes are root-owned on the host. See hand_back_ownership.
HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"

hand_back_ownership() {
    [ "$HOST_UID" = "0" ] && return 0
    chown -R "$HOST_UID:$HOST_GID" "$SRC/$PKG" 2>/dev/null || true
    chown -R "$HOST_UID:$HOST_GID" "$OUT" 2>/dev/null || true
}
trap hand_back_ownership EXIT

echo "=============================================================="
echo " packaging $PKG for ros-$ROS_DISTRO_ARG on ubuntu/$OS_VERSION"
echo " arch: $(dpkg --print-architecture)"
echo "=============================================================="

# ---------------------------------------------------------------- tooling
echo "--- installing packaging tooling"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    python3-bloom python3-catkin-pkg \
    fakeroot dpkg-dev debhelper devscripts equivs apt-utils

for c in bloom-generate catkin_generate_changelog fakeroot dpkg-buildpackage mk-build-deps apt-ftparchive; do
    command -v "$c" >/dev/null || { echo "FATAL: missing $c" >&2; exit 1; }
done

# rosdep maps <depend> names to Debian names. Duatic names are not in the public index, so they
# resolve to nothing unless ROSDEP_YAML points at a private mapping. Optional.
echo "--- rosdep update"
[ -f /etc/ros/rosdep/sources.list.d/20-default.list ] || rosdep init
if [ -n "${ROSDEP_YAML:-}" ]; then
    [ -f "$ROSDEP_YAML" ] || { echo "FATAL: ROSDEP_YAML=$ROSDEP_YAML does not exist" >&2; exit 1; }
    echo "    private rosdep source: $ROSDEP_YAML"
    # Sorts before 20-default.list, so it is consulted first.
    echo "yaml file://$ROSDEP_YAML" > /etc/ros/rosdep/sources.list.d/10-local.list
else
    echo "    NO private rosdep source: Duatic dependencies will not resolve"
fi
rosdep update --rosdistro "$ROS_DISTRO_ARG"

# ---------------------------------------------------------------- 1. changelog
# bloom requires CHANGELOG.rst. catkin_generate_changelog finds the VCS by .git, so it runs at
# the repository root and writes one per package; only this package's is kept.
# Locate the package: `<repo>/<package_name>/` is a convention, not a rule.
cd "$SRC"
PKG_DIR=""
while IFS= read -r px; do
    if grep -q "<name>[[:space:]]*$PKG[[:space:]]*</name>" "$px" 2>/dev/null; then
        PKG_DIR="$(dirname "$px")"; break
    fi
done < <(find . -name package.xml -not -path '*/.git/*' | sort)
[ -n "$PKG_DIR" ] || { echo "FATAL: no package.xml declaring <name>$PKG</name> under $SRC" >&2; exit 1; }
PKG_DIR="${PKG_DIR#./}"
echo "--- $PKG found at ${PKG_DIR:-<repository root>}"

echo "--- generating CHANGELOG.rst (written back into the repo)"
if [ -f "$PKG_DIR/CHANGELOG.rst" ]; then
    echo "    $PKG_DIR/CHANGELOG.rst already present, leaving it alone"
else
    git config --global --add safe.directory "$SRC" 2>/dev/null || true
    pre_existing="$(find . -name CHANGELOG.rst)"
    catkin_generate_changelog --all
    find . -name CHANGELOG.rst | while read -r f; do
        if [ "$f" = "./$PKG_DIR/CHANGELOG.rst" ]; then
            continue
        fi
        if printf '%s\n' "$pre_existing" | grep -qxF "$f"; then
            continue
        fi
        echo "    discarding $f (not part of this build)"
        rm -f "$f"
    done
    echo "    >>> REVIEW AND TRIM $PKG_DIR/CHANGELOG.rst BEFORE COMMITTING <<<"
fi

# ---------------------------------------------------------------- 2. scratch copy
echo "--- copying to scratch build dir (keeps debian/ and .deb out of git)"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cp -a "$SRC/$PKG_DIR" "$BUILD/$PKG"
cd "$BUILD/$PKG"

# ---------------------------------------------------------------- 3. bloom
echo "--- bloom-generate rosdebian"
# bloom-generate, not bloom-release: bloom-release targets the public rosdistro.
bloom-generate rosdebian \
    --os-name ubuntu --os-version "$OS_VERSION" --ros-distro "$ROS_DISTRO_ARG"

# Where this package came from. A version says which release it is; only the commit says what it
# was built from. dpkg-gencontrol copies XB- fields into the binary package with the prefix
# stripped, so a robot can answer this with `dpkg -s`.
GIT_COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$GIT_COMMIT" != "unknown" ] && ! git -C "$SRC" diff --quiet HEAD 2>/dev/null; then
    GIT_COMMIT="$GIT_COMMIT-dirty"
fi
GIT_URL="$(git -C "$SRC" config --get remote.origin.url 2>/dev/null || echo unknown)"
echo "--- source $GIT_COMMIT"
python3 - "$GIT_COMMIT" "$GIT_URL" <<'PYCTL'
import sys, pathlib
commit, url = sys.argv[1], sys.argv[2]
p = pathlib.Path('debian/control')
stanzas = p.read_text().split('\n\n')
out = []
for st in stanzas:
    if not st.strip():
        continue
    lines = st.rstrip('\n').split('\n')
    if st.startswith('Source:') and url != 'unknown':
        lines.append(f'Vcs-Git: {url}')
    elif st.startswith('Package:'):
        add = [f'XB-Duatic-Vcs-Commit: {commit}']
        if url != 'unknown':
            add.append(f'XB-Duatic-Vcs-Url: {url}')
        # Before Description, which continues over following indented lines and has to stay last.
        at = next((i for i, l in enumerate(lines) if l.startswith('Description:')), len(lines))
        lines[at:at] = add
    out.append('\n'.join(lines))
p.write_text('\n\n'.join(out) + '\n')
PYCTL

echo
echo "--- generated debian/control (inspect the dependencies):"
grep -E '^(Package|Source|Architecture|Depends|Build-Depends|XB-Duatic|Vcs-):' debian/control || true
echo

# ---------------------------------------------------------------- 4. build
# A package build-depending on another Duatic package needs the local repository visible here,
# so each package publishes before anything depending on it builds.
LOCAL_REPO="${LOCAL_REPO:-/builder/repo}"
# Re-indexed every build: a stale index hides the package just built. apt-ftparchive rather
# than dpkg-scanpackages, which omits .ddeb.
if ls "$LOCAL_REPO"/*.deb >/dev/null 2>&1; then
    ( cd "$LOCAL_REPO" && apt-ftparchive packages . > Packages )
fi
if [ -f "$LOCAL_REPO/Packages" ]; then
    echo "--- registering local apt repository at $LOCAL_REPO"
    echo "deb [trusted=yes] file:$LOCAL_REPO ./" > /etc/apt/sources.list.d/duatic-local.list
    apt-get update -qq
else
    echo "--- no local apt repository at $LOCAL_REPO (fine for a leaf package)"
fi

echo "--- installing build dependencies"

mk-build-deps --install --remove --tool='apt-get -y -qq --no-install-recommends' debian/control

echo "--- building"
# The ROS setup scripts read variables they do not set, so -u has to come off around them.
set +u
# shellcheck disable=SC1090
source "/opt/ros/$ROS_DISTRO_ARG/setup.bash"
set -u
fakeroot debian/rules binary

# ---------------------------------------------------------------- 5. collect + inspect
# Debug packages use a .ddeb extension, which a *.deb glob misses.
mkdir -p "$OUT"
shopt -s nullglob
artifacts=("$BUILD"/*.deb "$BUILD"/*.ddeb)
shopt -u nullglob
[ ${#artifacts[@]} -gt 0 ] || { echo "FATAL: no packages produced in $BUILD" >&2; exit 1; }
cp "${artifacts[@]}" "$OUT"/

echo
echo "=============================================================="
echo " artifacts"
echo "=============================================================="
ls -la "$OUT"

if ! ls "$OUT"/*-dbgsym_* >/dev/null 2>&1; then
    echo
    echo "WARNING: no dbgsym package. Debug symbols cannot be added to a release after"
    echo "         the fact without rebuilding it, so this is worth resolving now."
fi

# Only what this run produced. `awk NR<=30` rather than `head`: head closes the pipe, and the
# resulting SIGPIPE under `set -o pipefail` fails the build after the .deb was written.
shopt -s nullglob
DEB_NAME="ros-${ROS_DISTRO_ARG}-${PKG//_/-}"
for d in "$OUT/$DEB_NAME"_*.deb "$OUT/$DEB_NAME"-dbgsym_*.ddeb; do
    echo
    echo "----- $(basename "$d") : metadata"
    dpkg -I "$d" | sed 's/^/    /'
    echo "----- $(basename "$d") : contents (first 30)"
    dpkg -c "$d" | awk 'NR<=30 {print "    " $NF}'
done
shopt -u nullglob

echo
echo "Done. Next: ./make_repo.sh"
