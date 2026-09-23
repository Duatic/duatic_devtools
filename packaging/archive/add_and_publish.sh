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

# Route delivered packages into their archive roots, publish, and read the index back.
#
# Runs on the publish host, where the signing key is. The packages are expected in $ARCHIVE/out,
# built elsewhere.
#
# Usage:  add_and_publish.sh <package>:<root>:<version> [...]

set -euo pipefail

ARCHIVE="${ARCHIVE:-$HOME/archive}"
OS_VERSION="${OS_VERSION:-noble}"
CHANNEL="${CHANNEL:-nightly}"
SUITE="${SUITE:-${OS_VERSION}-${CHANNEL}}"
IMAGE="${IMAGE:-ubuntu:24.04}"

[ $# -gt 0 ] || { echo "FATAL: no <package>:<root>:<version> specs given" >&2; exit 1; }
[ -x "$ARCHIVE/publish_archives.sh" ] \
    || { echo "FATAL: no publish_archives.sh in $ARCHIVE" >&2; exit 1; }
# The routing lists are per distro, and appending to the wrong one publishes a package under a
# distro it was not built for. Named rather than defaulted, because a default would be a guess.
[ -n "${DISTRO:-}" ] || { echo "FATAL: DISTRO is not set" >&2; exit 1; }
cd "$ARCHIVE"
[ -d lists ] || { echo "FATAL: no lists/ in $ARCHIVE. Run gen_release_set.sh first." >&2; exit 1; }

echo "--- routing packages to archive roots"
for spec in "$@"; do
    case "$spec" in *:*:*) ;; *) echo "FATAL: malformed spec '$spec'" >&2; exit 1 ;; esac
    # Split on the first two colons only: a Debian version may carry an epoch, as in 1:2.0.
    pkg="${spec%%:*}"; rest="${spec#*:}"
    root="${rest%%:*}"; ver="${rest#*:}"
    for field in "$pkg" "$root" "$ver"; do
        [ -n "$field" ] || { echo "FATAL: empty field in spec '$spec'" >&2; exit 1; }
    done
    ls "out/${pkg}"_*.deb >/dev/null 2>&1 \
        || { echo "FATAL: no ${pkg}_*.deb in $ARCHIVE/out" >&2; exit 1; }
    # The root the package itself declares, not the one the caller asked for. Routing decides who
    # may fetch a package, so a caller that could name any root could publish a licensed one into
    # the open archive.
    for deb in "out/${pkg}"_*.deb; do
        declared="$(dpkg-deb -f "$deb" Duatic-Archive-Root 2>/dev/null || true)"
        if [ -z "$declared" ]; then
            [ "${ALLOW_UNDECLARED_ROOT:-0}" = "1" ] || {
                echo "FATAL: $(basename "$deb") declares no archive root." >&2
                echo "  Add <export><duatic_archive_root> to its package.xml and rebuild." >&2
                echo "  Set ALLOW_UNDECLARED_ROOT=1 to route it by hand anyway." >&2
                exit 1
            }
        elif [ "$declared" != "$root" ]; then
            echo "FATAL: $(basename "$deb") declares root '$declared', asked to publish to '$root'" >&2
            exit 1
        fi
    done
    # Named as gen_release_set.sh names it, so that generator still owns the file and still
    # prunes it. A list outside its <root>-<distro>.txt scheme is never cleaned up, and a
    # package that moves to a different root stays published under the old one.
    list="lists/$(printf '%s' "$root" | tr '/' '-')-${DISTRO}.txt"
    [ -f "$list" ] || printf '# root: %s\n' "$root" > "$list"
    grep -qxF "$pkg" "$list" || printf '%s\n' "$pkg" >> "$list"
    echo "    $pkg -> $root  ($list)"
done

echo "--- publishing"
# The passphrase file is named as the container sees it, since that is where gpg runs.
pass_args=()
if [ -n "${GPG_PASSPHRASE_FILE:-}" ]; then
    pass_args=(-e "GPG_PASSPHRASE_FILE=$GPG_PASSPHRASE_FILE")
elif [ -f "$ARCHIVE/.passphrase" ]; then
    pass_args=(-e "GPG_PASSPHRASE_FILE=/work/.passphrase")
fi
docker run --rm \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -e "EXPECTED_KEY_FPR=${EXPECTED_KEY_FPR:-}" \
    -e "ALLOW_THROWAWAY_KEY=${ALLOW_THROWAWAY_KEY:-0}" \
    -e "OS_VERSION=$OS_VERSION" -e "CHANNEL=$CHANNEL" \
    "${pass_args[@]}" \
    -v "$PWD:/work" -v "$PWD/out:/out" -v "$PWD/dist:/dist" \
    "$IMAGE" /work/publish_archives.sh

echo "--- verifying the published index"
# publish_archives.sh skips a root it finds no packages for and still succeeds, so its exit code
# alone cannot show that a delivery landed.
fail=0
for spec in "$@"; do
    pkg="${spec%%:*}"; rest="${spec#*:}"
    root="${rest%%:*}"; ver="${rest#*:}"
    case "$root" in
        public) tree="dist/public" ;;
        *)      tree="dist/private/$root" ;;
    esac
    # Every architecture the root publishes, since which one a package carries is a property of
    # the build. A match in one index says the package published, not that every architecture
    # of it did.
    found_in=""
    shopt -s nullglob
    indexes=("$tree/dists/$SUITE/main/binary-"*/Packages)
    shopt -u nullglob
    if [ ${#indexes[@]} -eq 0 ]; then
        echo "    FAIL  no index under $tree/dists/$SUITE"; fail=1; continue
    fi
    for idx in "${indexes[@]}"; do
        # Per stanza, not per line: aptly writes Priority, Section, Maintainer and Architecture
        # between Package and Version, so the two are never adjacent.
        if awk -v p="$pkg" -v v="$ver" '
                /^$/             { pkg=""; ver=""; next }
                /^Package: /     { pkg=substr($0, 10) }
                /^Version: /     { ver=substr($0, 10) }
                pkg==p && ver==v { found=1 }
                END              { exit !found }
            ' "$idx"; then
            arch="${idx%/Packages}"
            found_in="$found_in ${arch##*binary-}"
        fi
    done
    if [ -n "$found_in" ]; then
        echo "    ok    $pkg $ver in $tree [${found_in# }]"
    else
        echo "    FAIL  $pkg $ver not indexed in $tree"
        fail=1
    fi
done
exit "$fail"
