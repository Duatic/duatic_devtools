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
# Each channel publishes its own deliveries: a delivery arriving in out/ moves to out/<channel>/,
# and that channel's suites are published from there alone. CHANNEL is stable for releases and
# edge for builds of main; edge keeps the newest EDGE_KEEP builds of each package (default 3).
#
# A channel ending in a digit, such as product1, is a product line: a set of releases customers
# install from. It takes only patch releases of what it holds: a delivery whose X.Y the line holds
# no version of is refused. New versions enter a line with SET_RELEASE=1, which copies the named
# releases from stable instead of taking a delivery. A stable delivery is also published into every
# line holding a version of the same package with the same X.Y.
#
# Usage:  add_and_publish.sh <package>:<root>:<version> [...]

set -euo pipefail

ARCHIVE="${ARCHIVE:-$HOME/archive}"
CHANNEL="${CHANNEL:-stable}"
IMAGE="${IMAGE:-ubuntu:24.04}"
# Roots besides public that are open, comma or space separated. Every other root is gated.
OPEN_ROOTS="${OPEN_ROOTS:-}"

[ $# -gt 0 ] || { echo "FATAL: no <package>:<root>:<version> specs given" >&2; exit 1; }
[ -x "$ARCHIVE/publish_archives.sh" ] \
    || { echo "FATAL: no publish_archives.sh in $ARCHIVE" >&2; exit 1; }
# The routing lists are per distro, and appending to the wrong one publishes a package under a
# distro it was not built for. Named rather than defaulted, because a default would be a guess.
[ -n "${DISTRO:-}" ] || { echo "FATAL: DISTRO is not set" >&2; exit 1; }
printf '%s' "$CHANNEL" | grep -qE '^[a-z][a-z0-9]*$' || { echo "FATAL: invalid CHANNEL '$CHANNEL'" >&2; exit 1; }
SET_RELEASE="${SET_RELEASE:-0}"
case "$SET_RELEASE" in 0|1) ;; *) echo "FATAL: SET_RELEASE is '$SET_RELEASE', not 0 or 1" >&2; exit 1 ;; esac

# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
lock_archive
if [ "$SET_RELEASE" = 1 ] && ! is_line "$CHANNEL"; then
    echo "FATAL: SET_RELEASE takes a product line, such as product1, not '$CHANNEL'" >&2; exit 1
fi
OS_VERSION="${OS_VERSION:-$(ubuntu_for "$DISTRO")}"
[ -n "$OS_VERSION" ] \
    || { echo "FATAL: no Ubuntu release known for DISTRO=$DISTRO; set OS_VERSION" >&2; exit 1; }
SUITE="${SUITE:-${OS_VERSION}-${CHANNEL}}"
# The distros whose lists the suite is published from: those built on the same Ubuntu release.
LIST_DISTROS="$DISTRO"
for d in $(distros_on "$OS_VERSION"); do
    [ "$d" = "$DISTRO" ] || LIST_DISTROS="$LIST_DISTROS $d"
done
cd "$ARCHIVE"
[ -d lists ] || { echo "FATAL: no lists/ in $ARCHIVE. Run gen_release_set.sh first." >&2; exit 1; }

# stable takes releases and edge builds of main, refused before anything moves.
for spec in "$@"; do
    # Names and versions become paths below, so nothing but Debian's own forms passes.
    pkg="${spec%%:*}"; ver="${spec##*:}"
    printf '%s' "$pkg" | grep -qE '^[a-z0-9][a-z0-9+.-]+$' \
        || { echo "FATAL: '$pkg' in '$spec' is not a Debian package name" >&2; exit 1; }
    printf '%s' "$ver" | grep -qE '^[0-9][A-Za-z0-9.+~-]*$' \
        || { echo "FATAL: '$ver' in '$spec' is not a Debian version" >&2; exit 1; }
    case "$CHANNEL:${spec##*:}" in
        stable:*+git*) echo "FATAL: $spec is a build of main, and stable takes releases" >&2; exit 1 ;;
        edge:*+git*) ;;
        edge:*) echo "FATAL: $spec is not a build of main, and edge takes only those" >&2; exit 1 ;;
    esac
    if is_line "$CHANNEL"; then
        case "${spec##*:}" in
            *+git*) echo "FATAL: $spec is a build of main, and the line $CHANNEL takes releases" >&2; exit 1 ;;
        esac
    fi
done

# newest_held <line> <package> <version>: the newest version of the package the line holds with
# the same X.Y and Ubuntu release as <version>, or nothing.
newest_held() {
    local f v newest="" release
    release="$(printf '%s' "$3" | sed -nE 's/.*-[0-9]+([a-z]+)$/\1/p')"
    for f in "out/$1/$2"_*.deb; do
        [ -f "$f" ] || continue
        v="$(basename "$f" .deb)"; v="${v#*_}"; v="${v%_*}"
        [ "$(series_of "$v")" = "$(series_of "$3")" ] || continue
        # Only builds for the same Ubuntu release: a system package's name does not fix it.
        [ "$(printf '%s' "$v" | sed -nE 's/.*-[0-9]+([a-z]+)$/\1/p')" = "$release" ] || continue
        if [ -z "$newest" ] || dpkg --compare-versions "$v" gt "$newest"; then newest="$v"; fi
    done
    printf '%s' "$newest"
}

# line_takes <line> <package> <version>: the line holds the same X.Y, and nothing newer in it.
line_takes() {
    local held
    held="$(newest_held "$1" "$2" "$3")"
    [ -n "$held" ] && dpkg --compare-versions "$3" ge "$held"
}

# in_channel <package> <version> <channel>: the channel holds a .deb of that release.
in_channel() { ls "out/$3/${1}_${2}"_*.deb >/dev/null 2>&1; }

# copy_release <package> <version> <from> <to>: a release's packages, debug symbols and source.
# Files the target did not have are recorded in COPIED.
COPIED=()
copy_release() {
    local f
    for f in "out/$3/${1}_${2}"_*.deb "out/$3/${1}-dbgsym_${2}"_*.ddeb "out/$3/${1}_${2}.src.tar.gz"; do
        [ -f "$f" ] || continue
        [ -e "out/$4/$(basename "$f")" ] || COPIED+=("out/$4/$(basename "$f")")
        cp -p "$f" "out/$4/"
    done
}

# A set release refused after its copies leaves the line as it was, so a later patch publishing the
# line does not serve part of a set.
SET_PUBLISHING=0
undo_set() {
    [ "$SET_RELEASE" = 1 ] && [ "$SET_PUBLISHING" = 0 ] || return 0
    local f
    for f in "${COPIED[@]}"; do rm -f "$f"; done
}
trap undo_set EXIT

# Deliveries arrive in out/, and each channel publishes only its own.
OUT="out/$CHANNEL"
mkdir -p "$OUT"
if [ "$SET_RELEASE" = 1 ]; then
    for spec in "$@"; do
        pkg="${spec%%:*}"; ver="${spec##*:}"
        in_channel "$pkg" "$ver" stable \
            || { echo "FATAL: $pkg $ver is not in stable; a set release takes released versions" >&2; exit 1; }
    done
    for spec in "$@"; do
        pkg="${spec%%:*}"; ver="${spec##*:}"
        copy_release "$pkg" "$ver" stable "$CHANNEL"
    done
else
    if is_line "$CHANNEL"; then
        for spec in "$@"; do
            pkg="${spec%%:*}"; ver="${spec##*:}"
            line_takes "$CHANNEL" "$pkg" "$ver" || {
                echo "FATAL: $CHANNEL holds no $pkg $(series_of "$ver").x older than $ver; a line takes only" >&2
                echo "  newer patch releases of what it holds. A new version enters it with a set release" >&2
                echo "  (SET_RELEASE=1)." >&2
                exit 1
            }
        done
    fi
    for spec in "$@"; do
        pkg="${spec%%:*}"; ver="${spec##*:}"
        for f in "out/${pkg}_${ver}"_*.deb "out/${pkg}-dbgsym_${ver}"_*.ddeb "out/${pkg}_${ver}.src.tar.gz"; do
            [ -f "$f" ] && mv -f "$f" "$OUT/"
        done
    done
fi

# Open roots are fetchable without an entitlement.
OPEN=(public)
for r in ${OPEN_ROOTS//,/ }; do
    if ! printf '%s' "$r" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/+~-]*$' || [ "$r" = "unrouted" ]; then
        echo "FATAL: OPEN_ROOTS names an invalid root '$r'" >&2; exit 1
    fi
    OPEN+=("$r")
done
is_open() { local o; for o in "${OPEN[@]}"; do [ "$1" = "$o" ] && return 0; done; return 1; }

# The package names in each root for this distro. Lists are only written once the check passes.
declare -A PKGS_IN=()
for f in lists/*-"${DISTRO}".txt; do
    [ -f "$f" ] || continue
    r="$(sed -n 's/^# root: //p' "$f" | head -1)"
    [ -n "$r" ] || { echo "FATAL: $f declares no root" >&2; exit 1; }
    PKGS_IN["$r"]="${PKGS_IN[$r]:-} $(sed '/^#/d' "$f" | tr '\n' ' ')"
done

echo "--- routing packages to archive roots"
ROUTE_PKG=(); ROUTE_ROOT=(); ROUTE_LIST=()
for spec in "$@"; do
    case "$spec" in *:*:*) ;; *) echo "FATAL: malformed spec '$spec'" >&2; exit 1 ;; esac
    # Split on the first two colons only: a Debian version may carry an epoch, as in 1:2.0.
    pkg="${spec%%:*}"; rest="${spec#*:}"
    root="${rest%%:*}"; ver="${rest#*:}"
    for field in "$pkg" "$root" "$ver"; do
        [ -n "$field" ] || { echo "FATAL: empty field in spec '$spec'" >&2; exit 1; }
    done
    ls "$OUT/${pkg}"_*.deb >/dev/null 2>&1 \
        || { echo "FATAL: no ${pkg}_*.deb in $ARCHIVE/$OUT" >&2; exit 1; }
    # The root the package itself declares, not the one the caller asked for. Routing decides who
    # may fetch a package, so a caller that could name any root could publish a licensed one into
    # the open archive.
    for deb in "$OUT/${pkg}"_*.deb; do
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
    case " ${PKGS_IN[$root]:-} " in
        *" $pkg "*) ;;
        *) PKGS_IN["$root"]="${PKGS_IN[$root]:-} $pkg" ;;
    esac
    ROUTE_PKG+=("$pkg"); ROUTE_ROOT+=("$root"); ROUTE_LIST+=("$list")
    echo "    $pkg -> $root  ($list)"
done

# debs_of <name>: every .deb of <name> in this channel and in the builder output publish_archives.sh reads.
debs_of() {
    local d f
    for d in "$OUT" ../builder/out; do
        for f in "$d/$1"_*.deb; do [ -f "$f" ] && printf '%s\n' "$f"; done
    done
    return 0
}

echo "--- checking open roots depend on nothing gated"
# Every root each name is published in, as a package or through a Provides of one. A name in no
# list is not published here, so it is expected from the distribution or ROS and passes.
declare -A ROOTS_OF=()
for r in "${!PKGS_IN[@]}"; do
    for name in ${PKGS_IN[$r]}; do
        ROOTS_OF["$name"]="${ROOTS_OF[$name]:-} $r"
        mapfile -t debs < <(debs_of "$name")
        for deb in "${debs[@]}"; do
            for p in $(dpkg-deb -f "$deb" Provides | sed -E 's/\([^)]*\)//g; s/,/ /g'); do
                ROOTS_OF["$p"]="${ROOTS_OF[$p]:-} $r"
            done
        done
    done
done

# Every open root, so a dependency that has become gated-only is caught whichever root this run
# publishes. Version constraints are not checked, only names.
dep_fail=0
for root in "${!PKGS_IN[@]}"; do
    is_open "$root" || continue
    for pkg in ${PKGS_IN[$root]}; do
        mapfile -t debs < <(debs_of "$pkg")
        if [ ${#debs[@]} -eq 0 ]; then
            echo "WARN: $pkg in open root $root not checked: no .deb found"
            continue
        fi
        newest=""
        for deb in "${debs[@]}"; do
            v="$(dpkg-deb -f "$deb" Version)"
            if [ -z "$newest" ] || dpkg --compare-versions "$v" gt "$newest"; then newest="$v"; fi
        done
        for deb in "${debs[@]}"; do
            deps="$({ dpkg-deb -f "$deb" Depends; echo ,; dpkg-deb -f "$deb" Pre-Depends; } | tr '\n' ' ')"
            IFS=',' read -r -a relations <<< "$deps"
            for rel in "${relations[@]}"; do
                # Drop version constraints, architecture qualifiers and whitespace.
                rel="$(printf '%s' "$rel" | sed -E 's/\([^)]*\)//g; s/:[a-z0-9-]+//g; s/[[:space:]]+//g')"
                [ -n "$rel" ] || continue
                ok=0; gated=()
                IFS='|' read -r -a alts <<< "$rel"
                for alt in "${alts[@]}"; do
                    roots="${ROOTS_OF[$alt]:-}"
                    [ -n "$roots" ] || { ok=1; break; }
                    for r in $roots; do is_open "$r" && { ok=1; break; }; done
                    [ "$ok" = 1 ] && break
                    gated+=("$alt in${roots}")
                done
                [ "$ok" = 1 ] && continue
                echo "FATAL: $(basename "$deb") in open root '$root' depends on '$rel'," >&2
                echo "  which is published only in gated roots: ${gated[*]}" >&2
                v="$(dpkg-deb -f "$deb" Version)"
                if [ "$v" != "$newest" ]; then
                    echo "  It is version $v, not the newest $pkg present ($newest)." >&2
                    echo "  A stale .deb is still published: remove it from $(dirname "$deb")/." >&2
                fi
                dep_fail=1
            done
        done
    done
done
[ "$dep_fail" = 0 ] || {
    echo "  An open package may depend only on open or public packages, or on ones outside this archive." >&2
    echo "  No routing list was changed." >&2
    exit 1
}

for i in "${!ROUTE_PKG[@]}"; do
    list="${ROUTE_LIST[$i]}"
    [ -f "$list" ] || printf '# root: %s\n' "${ROUTE_ROOT[$i]}" > "$list"
    grep -qxF "${ROUTE_PKG[$i]}" "$list" || printf '%s\n' "${ROUTE_PKG[$i]}" >> "$list"
done

echo "--- placing sources in open roots"
# Before publishing, so a package declaring Duatic-Publish-Source is never served without its
# source. A gated root gets none: whoever may fetch a licensed binary is not offered its source.
for spec in "$@"; do
    pkg="${spec%%:*}"; rest="${spec#*:}"
    root="${rest%%:*}"; ver="${rest#*:}"
    is_open "$root" || continue
    declares=0
    for deb in "$OUT/${pkg}"_*.deb; do
        [ "$(dpkg-deb -f "$deb" Version)" = "$ver" ] || continue
        [ "$(dpkg-deb -f "$deb" Duatic-Publish-Source 2>/dev/null || true)" = true ] && declares=1
    done
    [ "$declares" = 1 ] || continue
    src="$OUT/${pkg}_${ver}.src.tar.gz"
    [ -f "$src" ] || { echo "FATAL: no $src in $ARCHIVE: $pkg declares that its source is published" >&2; exit 1; }
    case "$root" in
        public) tree="dist/public" ;;
        *)      tree="dist/private/$root" ;;
    esac
    mkdir -p "$tree/sources/$pkg"
    cp "$src" "$tree/sources/$pkg/"
    echo "    $pkg $ver -> $tree/sources/$pkg/"
done

# publish_channel <channel> <spec>...: publish the channel's suite on this Ubuntu release, then
# check that every spec landed in it.
publish_channel() {
    local ch="$1" suite out keep_args=() fail=0 spec pkg rest root ver tree found_in idx arch
    shift
    out="out/$ch"
    if [ "$ch" = "$CHANNEL" ]; then suite="$SUITE"; else suite="${OS_VERSION}-${ch}"; fi
    echo "--- publishing $suite"
    publisher_args
    if [ "$ch" = edge ]; then keep_args=(-e "KEEP_VERSIONS=${EDGE_KEEP:-3}"); fi
    docker run --rm \
        "${PUBLISHER_ARGS[@]}" \
        -e "OS_VERSION=$OS_VERSION" -e "CHANNEL=$ch" -e "LIST_DISTROS=$LIST_DISTROS" \
        "${keep_args[@]}" \
        -v "$PWD:/work" -v "$PWD/$out:/out" -v "$PWD/dist:/dist" \
        "$IMAGE" /work/publish_archives.sh \
        || { echo "FATAL: publishing $suite failed" >&2; return 1; }
    if [ "$ch" = edge ]; then prune_edge_sources; fi

    echo "--- verifying the published index"
    # publish_archives.sh skips a root it finds no packages for and still succeeds, so its exit
    # code alone cannot show that a delivery landed.
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
        indexes=("$tree/dists/$suite/main/binary-"*/Packages)
        shopt -u nullglob
        if [ ${#indexes[@]} -eq 0 ]; then
            echo "    FAIL  no index under $tree/dists/$suite"; fail=1; continue
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
            echo "    ok    $pkg $ver in $tree/dists/$suite [${found_in# }]"
        else
            echo "    FAIL  $pkg $ver not indexed in $tree/dists/$suite"
            fail=1
        fi
    done
    return "$fail"
}

status=0
SET_PUBLISHING=1
publish_channel "$CHANNEL" "$@" || status=1

# A release is also a patch of every line that holds the same X.Y of the package.
# Only a release stable published: one it failed to publish must not reach a line either. A release
# a line already holds is published again, so a retry repairs a line whose last publish failed.
if [ "$CHANNEL" = stable ] && [ "$status" = 0 ]; then
    for dir in out/*/; do
        line="$(basename "$dir")"
        is_line "$line" || continue
        patches=()
        for spec in "$@"; do
            pkg="${spec%%:*}"; ver="${spec##*:}"
            line_takes "$line" "$pkg" "$ver" || continue
            copy_release "$pkg" "$ver" stable "$line"
            patches+=("$spec")
        done
        [ ${#patches[@]} -gt 0 ] || continue
        echo "--- patching the line $line"
        publish_channel "$line" "${patches[@]}" || status=1
    done
fi
exit "$status"
