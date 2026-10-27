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
printf '%s' "$CHANNEL" | grep -qE '^[a-z]+$' || { echo "FATAL: invalid CHANNEL '$CHANNEL'" >&2; exit 1; }

# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
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

# Deliveries arrive in out/, and each channel publishes only its own.
OUT="out/$CHANNEL"
mkdir -p "$OUT"
for spec in "$@"; do
    pkg="${spec%%:*}"; ver="${spec##*:}"
    for f in "out/${pkg}_${ver}"_*.deb "out/${pkg}-dbgsym_${ver}"_*.ddeb "out/${pkg}_${ver}.src.tar.gz"; do
        [ -f "$f" ] && mv -f "$f" "$OUT/"
    done
done

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

echo "--- publishing"
publisher_args
keep_args=()
if [ "$CHANNEL" = edge ]; then keep_args=(-e "KEEP_VERSIONS=${EDGE_KEEP:-3}"); fi
docker run --rm \
    "${PUBLISHER_ARGS[@]}" \
    -e "OS_VERSION=$OS_VERSION" -e "CHANNEL=$CHANNEL" -e "LIST_DISTROS=$LIST_DISTROS" \
    "${keep_args[@]}" \
    -v "$PWD:/work" -v "$PWD/$OUT:/out" -v "$PWD/dist:/dist" \
    "$IMAGE" /work/publish_archives.sh
if [ "$CHANNEL" = edge ]; then prune_edge_sources; fi

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
