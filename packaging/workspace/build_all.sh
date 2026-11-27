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

# Build every package in packages.txt that declares an archive root, in an order computed from what
# they declare, into ../archive/out, with logs/<package>.log and a manifest.json of what was built.
#
# Each successful build lands in staging/, which the next build mounts as an apt source: a
# package that build-depends on another cannot build until that one is installable.
#
# Nothing is committed or tagged. CHANGELOG.rst is written into the working tree.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"   # the packaging/ directory, not the repository root

fatal() { echo "FATAL: $*" >&2; exit 1; }
# A run that stops early leaves no manifest of an earlier run behind.
rm -f "$PKG/archive/out/manifest.json"

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
STOP_ON_FAILURE="${STOP_ON_FAILURE:-1}"
case "$STOP_ON_FAILURE" in 0 | 1) ;; *) fatal "STOP_ON_FAILURE is '$STOP_ON_FAILURE', not 0 or 1" ;; esac
ARCHIVE_CHANNELS="${ARCHIVE_CHANNELS:-stable}"
# The same rule as build_pkg.sh, checked before any build.
if [ -n "${DEB_REVISION:-}" ] && ! [[ "$DEB_REVISION" =~ ^[0-9]+$ ]]; then fatal "DEB_REVISION '$DEB_REVISION' is not digits"; fi
[ -z "${VERSION_SUFFIXES:-}" ] || [ -f "$VERSION_SUFFIXES" ] || fatal "VERSION_SUFFIXES=$VERSION_SUFFIXES does not exist"
# Mounted into each build as single files, so they have to exist: docker would create a directory.
if [ -n "${ARCHIVE_URL:-}" ]; then
    [ -f "${ARCHIVE_KEYRING:-}" ] || fatal "ARCHIVE_URL needs ARCHIVE_KEYRING, the archive's public key"
    keyring="$(realpath "$ARCHIVE_KEYRING")"
fi
case "${ARCHIVE_CLIENT_CERT:+cert}${ARCHIVE_CLIENT_KEY:+key}" in
    cert | key) fatal "ARCHIVE_CLIENT_CERT and ARCHIVE_CLIENT_KEY are given together" ;;
    certkey)
        [ -f "$ARCHIVE_CLIENT_CERT" ] || fatal "ARCHIVE_CLIENT_CERT=$ARCHIVE_CLIENT_CERT does not exist"
        [ -f "$ARCHIVE_CLIENT_KEY" ] || fatal "ARCHIVE_CLIENT_KEY=$ARCHIVE_CLIENT_KEY does not exist"
        client_cert="$(realpath "$ARCHIVE_CLIENT_CERT")"
        client_key="$(realpath "$ARCHIVE_CLIENT_KEY")"
        ;;
esac
echo "building for $ROS_DISTRO_TARGET on ubuntu $OS_VERSION, using $BUILD_IMAGE"
OUT="$PKG/archive/out"
LOGS="$OUT/logs"
STAGING="$HERE/staging"
mkdir -p "$OUT" "$LOGS" "$STAGING"
rm -f "$LOGS"/*.log
# Inside the workspace: the builds mount it, and a Docker daemon on another host shares only that.
work="$(mktemp -d "$HERE/.work.XXXXXX")"
trap 'rm -rf "$work"' EXIT
: > "$work/manifest.tsv"

# Topological order over the release set, from the build and runtime dependencies each package declares.
# One line per package: "build", name, repository, kind, root, whether the root is gated, suffix.
PLAN="$(python3 - "$HERE" "${VERSION_SUFFIXES:-}" <<'PY'
import sys, pathlib, xml.etree.ElementTree as ET
here, suffix_file = pathlib.Path(sys.argv[1]), sys.argv[2]
wanted = set(here.joinpath('packages.txt').read_text().split())
deps, build, where, kinds, roots, gated = {}, {}, {}, {}, {}, set()
for px in (here / 'src').rglob('package.xml'):
    if '.git' in px.parts: continue
    try: r = ET.parse(px).getroot()
    except Exception: continue
    n = (r.findtext('name') or '').strip()
    root = (r.findtext('export/duatic_archive_root') or '').strip()
    # Every root an archive URL may name for a client certificate, built here or not.
    if root not in ('', 'public'): gated.add(root)
    if n not in wanted: continue
    d = set()
    for tag in ('depend', 'build_depend', 'buildtool_depend', 'build_export_depend'):
        for e in r.findall(tag):
            if e.text and e.text.strip() in wanted: d.add(e.text.strip())
    build[n] = set(d)
    # Runtime too: installing a build dependency installs its runtime dependencies, built first.
    for tag in ('exec_depend', 'run_depend'):
        for e in r.findall(tag):
            if e.text and e.text.strip() in wanted: d.add(e.text.strip())
    deps[n] = d
    where[n] = px.parent.relative_to(here / 'src').parts[0]
    kinds[n] = (r.findtext('export/duatic_package_kind') or '').strip() or 'ros'
    roots[n] = root
    if kinds[n] not in ('ros', 'system'):
        sys.exit(f"{px}: duatic_package_kind is '{kinds[n]}', not ros or system")
# An unrouted package is never published, so a published package depending on it would not install.
unrouted = [f"{n} depends on {d}" for n in sorted(deps) if roots[n] for d in sorted(deps[n]) if not roots[d]]
if unrouted:
    sys.exit("FATAL: these depend on a package that declares no <duatic_archive_root>, so they would not install:\n  "
             + "\n  ".join(unrouted))
order, seen, marked = [], set(), set()
def visit(n, chain=()):
    if n in seen: return
    if n in marked:                      # a cycle would otherwise recurse forever
        loop = chain[chain.index(n):] + (n,)
        runtime = any(b not in build[a] for a, b in zip(loop, loop[1:]))
        print(f"# cycle{' through runtime dependencies' if runtime else ''}: {' -> '.join(loop)}", file=sys.stderr)
        return
    marked.add(n)
    for d in sorted(deps.get(n, ())): visit(d, chain + (n,))
    marked.discard(n); seen.add(n); order.append(n)
for n in sorted(deps): visit(n)

suffixes = {}
if suffix_file:
    for line in pathlib.Path(suffix_file).read_text().splitlines():
        if not line.strip(): continue
        parts = line.split()
        if len(parts) != 2: sys.exit(f"FATAL: VERSION_SUFFIXES: '{line}' is not <repository> <suffix>")
        suffixes[parts[0]] = parts[1]
routed = [n for n in order if roots[n]]
missing = sorted({where[n] for n in routed if suffix_file and where[n] not in suffixes})
if missing: sys.exit(f"FATAL: VERSION_SUFFIXES has no suffix for {', '.join(missing)}")
for g in sorted(gated): print(f"gated\t{g}")
for n in order:
    if not roots[n]: print(f"skip\t{n}")
for n in routed:
    print('\t'.join(('build', n, where[n], kinds[n], roots[n], str(int(roots[n] in gated)), suffixes.get(where[n], ''))))
PY
)" || exit 1
grep -q '^build' <<< "$PLAN" || fatal "nothing to build: no package in packages.txt declares <duatic_archive_root>"

skipped="$(awk -F'\t' '$1 == "skip" { printf " %s", $2 }' <<< "$PLAN")"
[ -z "$skipped" ] || echo "skipped, declaring no <duatic_archive_root>:$skipped"
# A package outside the gated roots builds against the other roots only, without the client
# certificate, so a dependency on a gated package fails its build. A gated root's URL ends in the root.
open_urls=""
for url in ${ARCHIVE_URL:-}; do
    keep=1
    for g in $(awk -F'\t' '$1 == "gated" { print $2 }' <<< "$PLAN"); do
        case "${url%/}" in */"$g") keep=0 ;; esac
    done
    [ "$keep" = 0 ] || open_urls="${open_urls:+$open_urls }$url"
done

# The packages built, as a JSON list of {package, version, root, distro, arch, files, seconds}.
write_manifest() {
    python3 - "$work/manifest.tsv" "$OUT/manifest.json" "$ROS_DISTRO_TARGET" <<'PY'
import json, sys
tsv, dest, distro = sys.argv[1:]
built = []
for line in open(tsv).read().splitlines():
    pkg, root, seconds, files = line.split('\t')
    files = files.split()
    deb = next(f for f in files if f.endswith('.deb'))
    _, version, arch = deb[:-len('.deb')].split('_')
    built.append({'package': pkg, 'version': version, 'root': root, 'distro': distro, 'arch': arch,
                  'files': files, 'seconds': int(seconds)})
with open(dest, 'w') as out:
    json.dump(built, out, indent=2)
    out.write('\n')
PY
}

built=0; failed=0; failures=""
while IFS=$'\t' read -r what pkg repo kind root gated suffix; do
    [ "$what" = build ] || continue
    # A system package builds in plain Ubuntu, on the same release.
    image="$BUILD_IMAGE"
    [ "$kind" = system ] && image="ubuntu:$OS_VERSION"
    archive=()
    if [ -n "${ARCHIVE_URL:-}" ]; then
        urls="$open_urls"
        [ "$gated" = 1 ] && urls="$ARCHIVE_URL"
        archive=(-e ARCHIVE_URL="$urls" -e ARCHIVE_CHANNELS="$ARCHIVE_CHANNELS"
            -e ARCHIVE_KEYRING=/archive/keyring.gpg -v "$keyring:/archive/keyring.gpg:ro")
        if [ "$gated" = 1 ] && [ -n "${ARCHIVE_CLIENT_CERT:-}" ]; then
            archive+=(-e ARCHIVE_CLIENT_CERT=/archive/client.crt -e ARCHIVE_CLIENT_KEY=/archive/client.key
                -v "$client_cert:/archive/client.crt:ro" -v "$client_key:/archive/client.key:ro")
        fi
    fi
    log="$LOGS/$pkg.log"
    mkdir "$work/$pkg"
    printf '=== %-42s (%s, %s)\n' "$pkg" "$repo" "$root"
    start=$SECONDS
    status=0
    docker run --rm -i \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -e ROSDEP_YAML="/rosdep/$ROSDEP_FILE" \
        -e ROS_DISTRO="$ROS_DISTRO_TARGET" \
        -e OS_VERSION="$OS_VERSION" \
        -e DEB_VERSION_SUFFIX="$suffix" \
        -e DEB_REVISION="${DEB_REVISION:-}" \
        "${archive[@]}" \
        -v "$HERE/src/$repo:/src" \
        -v "$PKG/builder:/builder" \
        -v "$PKG/archive/rosdep:/rosdep" \
        -e LOCAL_REPO=/staging \
        -v "$STAGING:/staging" \
        -v "$work/$pkg:/out" \
        "$image" \
        /builder/build_pkg.sh "$pkg" < /dev/null > "$log" 2>&1 || status=$?
    if [ "$status" = 0 ] && ! ls "$work/$pkg"/*.deb >/dev/null 2>&1; then
        echo "build_all.sh: the build succeeded, but no .deb reached $work/$pkg, which it mounts as /out" >> "$log"
        status=1
    fi
    if [ "$status" = 0 ]; then
        seconds=$((SECONDS - start))
        # Into out/, and into staging so the next package can build against it. .ddeb too, since a
        # *.deb glob misses debug packages.
        files=""
        for a in "$work/$pkg"/*; do
            [ -f "$a" ] || continue
            f="$(basename "$a")"
            mv -f "$a" "$OUT/$f"
            case "$f" in *.deb | *.ddeb) cp -f "$OUT/$f" "$STAGING/" ;; esac
            files="$files $f"
        done
        printf '%s\t%s\t%s\t%s\n' "$pkg" "$root" "$seconds" "${files# }" >> "$work/manifest.tsv"
        echo "    ok, ${seconds}s"; built=$((built+1))
    else
        echo "    FAILED: $log"; failed=$((failed+1)); failures="$failures $pkg"
        if [ "$STOP_ON_FAILURE" = 1 ]; then
            write_manifest || { rm -f "$OUT/manifest.json"; fatal "could not write $OUT/manifest.json"; }
            fatal "$pkg did not build; stopped, so nothing after it in the order was attempted"
        fi
    fi
done <<< "$PLAN"
write_manifest || { rm -f "$OUT/manifest.json"; fatal "could not write $OUT/manifest.json"; }
echo
echo "  $built built, $failed failed"
[ -n "$failures" ] && echo "  failures:$failures"
[ -n "$skipped" ] && echo "  skipped, declaring no <duatic_archive_root>:$skipped"
echo "  manifest: $OUT/manifest.json"
# Non-zero when anything failed, so CI does not pass on a partial build.
[ "$failed" -eq 0 ]
