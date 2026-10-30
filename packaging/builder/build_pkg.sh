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

export DEBIAN_FRONTEND=noninteractive

PKG="${1:?usage: build_pkg.sh <package_name>}"
SRC=/src            # the repository, mounted read-write
OUT=/out            # where .debs are copied out to
BUILD=/tmp/build
ROS_DISTRO_ARG="${ROS_DISTRO:-jazzy}"
# Each LTS ROS 2 distro has one Tier 1 Ubuntu release for its whole support life (REP 2000).
# Rolling has no such commitment: it tracks whatever Ubuntu ROS's own tooling currently targets,
# so this entry is a snapshot that we have to revalidate.
case "$ROS_DISTRO_ARG" in
    humble) os_version_default=jammy ;;
    jazzy | kilted) os_version_default=noble ;;
    lyrical) os_version_default=resolute ;;
    rolling) os_version_default=resolute ;;
    *) os_version_default="" ;;
esac
OS_VERSION="${OS_VERSION:-$os_version_default}"
if [ -z "$OS_VERSION" ]; then
    echo "no known Ubuntu base for ROS_DISTRO=$ROS_DISTRO_ARG; set OS_VERSION explicitly" >&2
    exit 1
fi

# Runs as root against a bind mount, so writes are root-owned on the host. See hand_back_ownership.
HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"

hand_back_ownership() {
    [ "$HOST_UID" = "0" ] && return 0
    chown -R "$HOST_UID:$HOST_GID" "$SRC/${PKG_DIR:-$PKG}" 2>/dev/null || true
    chown -R "$HOST_UID:$HOST_GID" "$SRC/.git/lfs" 2>/dev/null || true
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
fakeroot dpkg-dev debhelper devscripts equivs apt-utils git-lfs

for c in bloom-generate catkin_generate_changelog fakeroot dpkg-buildpackage mk-build-deps apt-ftparchive git-lfs; do
    command -v "$c" >/dev/null || { echo "FATAL: missing $c" >&2; exit 1; }
done
# System-wide, so files stored in Git LFS compare as their pointers whatever the clone's own config.
git lfs install --system --skip-repo >/dev/null

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
# The container runs as root over a host-owned checkout, which git otherwise refuses to read.
git config --global --add safe.directory "$SRC" 2>/dev/null || true
PKG_DIR=""
while IFS= read -r px; do
    if grep -q "<name>[[:space:]]*$PKG[[:space:]]*</name>" "$px" 2>/dev/null; then
        PKG_DIR="$(dirname "$px")"; break
    fi
done < <(find . -name package.xml -not -path '*/.git/*' | sort)
[ -n "$PKG_DIR" ] || { echo "FATAL: no package.xml declaring <name>$PKG</name> under $SRC" >&2; exit 1; }
PKG_DIR="${PKG_DIR#./}"
echo "--- $PKG found at ${PKG_DIR:-<repository root>}"

# ---------------------------------------------------------------- archive dependencies
# With ARCHIVE_URL, the archive is an apt source for the build, and each dependency of this package
# it publishes is mapped for rosdep. ARCHIVE_KEYRING is its public key, ARCHIVE_CHANNELS the
# channels read, by default stable. Optional.
if [ -n "${ARCHIVE_URL:-}" ]; then
    [ -f "${ARCHIVE_KEYRING:-}" ] \
        || { echo "FATAL: ARCHIVE_URL needs ARCHIVE_KEYRING, the archive's public key" >&2; exit 1; }
    # A suite not published yet is read as empty; any other failure to reach one stops the build.
    suites=""
    for channel in ${ARCHIVE_CHANNELS:-stable}; do
        suite="$OS_VERSION-$channel"
        state="$(python3 - "${ARCHIVE_URL%/}/dists/$suite/InRelease" <<'PY'
import sys, urllib.error, urllib.request
url = sys.argv[1]
try:
    urllib.request.urlopen(url, timeout=60).close()
    print("published")
except urllib.error.HTTPError as e:
    if e.code != 404:
        sys.exit(f"FATAL: {url}: {e}")
    print("missing")
except urllib.error.URLError as e:
    if not isinstance(e.reason, FileNotFoundError):
        sys.exit(f"FATAL: {url}: {e.reason}")
    print("missing")
PY
)"
        if [ "$state" = published ]; then suites="$suites $suite"; else echo "--- $suite is not published yet"; fi
    done
fi
if [ -n "${ARCHIVE_URL:-}" ] && [ -z "$suites" ]; then
    echo "--- no suite of $ARCHIVE_URL is published yet, building without it"
elif [ -n "${ARCHIVE_URL:-}" ]; then
    echo "--- archive $ARCHIVE_URL,$suites"
    install -D -m 644 "$ARCHIVE_KEYRING" /etc/apt/keyrings/duatic-archive.gpg
    apt_archive=/tmp/archive-apt
    mkdir -p "$apt_archive/sources" "$apt_archive/lists/partial" "$apt_archive/cache/archives/partial"
    printf 'Types: deb\nURIs: %s\nSuites:%s\nComponents: main\nSigned-By: %s\n' \
        "$ARCHIVE_URL" "$suites" /etc/apt/keyrings/duatic-archive.gpg \
        > "$apt_archive/sources/duatic-archive.sources"
    # The archive on its own, without the system's sources or installed packages, so the mapping
    # names only what it publishes.
    apt_alone=(-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$apt_archive/sources"
        -o Dir::State::Lists="$apt_archive/lists" -o Dir::Cache="$apt_archive/cache"
        -o Dir::State::status=/dev/null)
    apt-get update -qq --error-on=any "${apt_alone[@]}"
    apt-cache "${apt_alone[@]}" dumpavail > "$apt_archive/Packages"
    /builder/archive_rosdep.sh "$SRC/${PKG_DIR:-.}/package.xml" "$ROS_DISTRO_ARG" "$OS_VERSION" \
        "$apt_archive/Packages" > "$apt_archive/rosdep.yaml"
    echo "    mapped from the archive:"
    sed 's/^/      /' "$apt_archive/rosdep.yaml"
    # After 10-local.list, before 20-default.list.
    echo "yaml file://$apt_archive/rosdep.yaml" > /etc/ros/rosdep/sources.list.d/15-archive.list
    rosdep update --rosdistro "$ROS_DISTRO_ARG"
    cp "$apt_archive/sources/duatic-archive.sources" /etc/apt/sources.list.d/
    apt-get update -qq --error-on=any
fi

echo "--- generating CHANGELOG.rst (written back into the repo)"
if [ -f "$PKG_DIR/CHANGELOG.rst" ]; then
    echo "    $PKG_DIR/CHANGELOG.rst already present, leaving it alone"
else
    pre_existing="$(find . -name CHANGELOG.rst)"
    catkin_generate_changelog --all
    find . -name CHANGELOG.rst | while read -r f; do
        cl="$PKG_DIR/CHANGELOG.rst"
        if [ "$f" = "./${cl#./}" ]; then
            continue
        fi
        if printf '%s\n' "$pre_existing" | grep -qxF "$f"; then
            continue
        fi
        echo "    discarding $f (not part of this build)"
        rm -f "$f"
    done
    # catkin_generate_changelog writes "Forthcoming"; the convention here is "Upcoming changes".
    # The underline is rewritten with the title, or docutils warns that it is too short.
    python3 - "$PKG_DIR/CHANGELOG.rst" <<'PYCL'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(
    'Forthcoming\n-----------\n', 'Upcoming changes\n----------------\n', 1))
PYCL
    echo "    >>> REVIEW AND TRIM $PKG_DIR/CHANGELOG.rst BEFORE COMMITTING <<<"
fi

# ---------------------------------------------------------------- 2. scratch copy
echo "--- copying to scratch build dir (keeps debian/ and .deb out of git)"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cp -a "$SRC/$PKG_DIR" "$BUILD/$PKG"
cd "$BUILD/$PKG"

# A Git LFS pointer in place of a file means its content was never fetched.
lfs_pointers=()
while IFS= read -r -d '' f; do
    first=""
    IFS= read -r first < "$f" || true
    if [ "$first" = "version https://git-lfs.github.com/spec/v1" ]; then lfs_pointers+=("${f#./}"); fi
done < <(find . -path ./.git -prune -o -type f -size -1024c -print0)
if [ ${#lfs_pointers[@]} -gt 0 ]; then
    echo "FATAL: $PKG holds Git LFS pointers instead of their content:" >&2
    printf '    %s\n' "${lfs_pointers[@]}" >&2
    echo "  Fetch it with git lfs pull, or check the repository out with Git LFS enabled." >&2
    exit 1
fi

# ---------------------------------------------------------------- 3. bloom
echo "--- bloom-generate rosdebian"
# bloom-generate, not bloom-release: bloom-release targets the public rosdistro.
bloom-generate rosdebian \
--os-name ubuntu --os-version "$OS_VERSION" --ros-distro "$ROS_DISTRO_ARG"

# A build of main between releases, e.g. +git20261027153012.ab12cd3: it sorts after the release it
# follows and before the next one.
if [ -n "${DEB_VERSION_SUFFIX:-}" ]; then
    printf '%s' "$DEB_VERSION_SUFFIX" | grep -qE '^[+~][A-Za-z0-9.+~]+$' \
        || { echo "FATAL: DEB_VERSION_SUFFIX '$DEB_VERSION_SUFFIX' must start with + or ~" >&2; exit 1; }
    sed -i -E "1s/^([^ ]+) \(([^-)]+)-/\1 (\2${DEB_VERSION_SUFFIX}-/" debian/changelog
    echo "--- version $(dpkg-parsechangelog -S Version)"
fi

# The commit this package was built from. dpkg-gencontrol copies XB- fields into the binary
# package with the prefix stripped, so a robot answers this with `dpkg -s`.
GIT_COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$GIT_COMMIT" != "unknown" ] && ! git -C "$SRC" diff --quiet HEAD 2>/dev/null; then
    GIT_COMMIT="$GIT_COMMIT-dirty"
fi
GIT_URL="$(git -C "$SRC" config --get remote.origin.url 2>/dev/null || echo unknown)"
echo "--- source $GIT_COMMIT"
# Whether the archive publishes this package's source beside it: true, false or undeclared.
PUBLISH_SOURCE="$(python3 -c "import xml.etree.ElementTree as E; print((E.parse('package.xml').getroot().findtext('export/duatic_publish_source') or '').strip())")"
case "$PUBLISH_SOURCE" in
    true | false | "") ;;
    *) echo "FATAL: <duatic_publish_source> is '$PUBLISH_SOURCE', not true or false" >&2; exit 1 ;;
esac
python3 - "$GIT_COMMIT" "$GIT_URL" "$PUBLISH_SOURCE" <<'PYCTL'
import sys, pathlib, xml.etree.ElementTree as ET
commit, url, publish_source = sys.argv[1], sys.argv[2], sys.argv[3]
# The root the package declares, carried into the binary so the publish host can check where it
# is being routed instead of trusting whoever asked. gen_release_set.sh reads the same field.
root = ''
try:
    root = (ET.parse('package.xml').getroot().findtext('export/duatic_archive_root') or '').strip()
except (OSError, ET.ParseError):
    pass
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
        if root:
            add.append(f'XB-Duatic-Archive-Root: {root}')
        if publish_source == 'true':
            add.append('XB-Duatic-Publish-Source: true')
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

# ---------------------------------------------------------------- 5. source
# What the build compiled: the package tree and every dependency FetchContent populated. An open
# archive publishes it beside the binary when the package declares <duatic_publish_source>.
shopt -s nullglob
fetched=("$BUILD/$PKG"/.obj-*/_deps/*-src)
shopt -u nullglob
# Fetched code may be GPL, which is distributed with its source, so its package has to decide.
if [ ${#fetched[@]} -gt 0 ] && [ -z "$PUBLISH_SOURCE" ]; then
    echo "FATAL: the build fetched $(printf '%s ' "${fetched[@]##*/}")but $PKG does not declare" >&2
    echo "  whether the archive publishes its source. Add to the <export> of its package.xml:" >&2
    echo "    <duatic_publish_source>true</duatic_publish_source>" >&2
    echo "  or false if no fetched licence requires it." >&2
    exit 1
fi
if [ "$PUBLISH_SOURCE" = true ]; then
    SRC_NAME="$(dpkg-parsechangelog -S Source)_$(dpkg-parsechangelog -S Version)"
    STAGE="$BUILD/source/$SRC_NAME"
    mkdir -p "$STAGE"
    cp -a "$SRC/$PKG_DIR/." "$STAGE/"
    for dep in "${fetched[@]}"; do
        mkdir -p "$STAGE/_deps"
        cp -a "$dep" "$STAGE/_deps/"
    done
    find "$STAGE" -name .git -prune -exec rm -rf {} +
    # Fixed order, owner and time, so every architecture's build writes the same bytes.
    tar --sort=name --mtime="@$(dpkg-parsechangelog -S Timestamp)" --owner=0 --group=0 --numeric-owner \
        -C "$BUILD/source" -cf - "$SRC_NAME" | gzip -n > "$BUILD/$SRC_NAME.src.tar.gz"
    echo "--- source $SRC_NAME.src.tar.gz: $(tar -tzf "$BUILD/$SRC_NAME.src.tar.gz" | grep -c '[^/]$') files"
fi

# ---------------------------------------------------------------- 6. collect + inspect
# Debug packages use a .ddeb extension, which a *.deb glob misses.
mkdir -p "$OUT"
shopt -s nullglob
artifacts=("$BUILD"/*.deb "$BUILD"/*.ddeb "$BUILD"/*.src.tar.gz)
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

# Only what this run produced. awk rather than head: head closes the pipe, and SIGPIPE under
# pipefail fails the build.
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
