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


# Switch a channel to what another channel publishes, for every Ubuntu release, so nightly can
# follow edge without a build. Runs on the publish host, like add_and_publish.sh.
#
# ROOTS limits it to those roots, space separated; empty switches every root.
#
# Usage:  promote.sh <from> <to>

set -euo pipefail

ARCHIVE="${ARCHIVE:-$HOME/archive}"
IMAGE="${IMAGE:-ubuntu:24.04}"
FROM="${1:?usage: promote.sh <from> <to>}"
TO="${2:?usage: promote.sh <from> <to>}"
for c in "$FROM" "$TO"; do
    printf '%s' "$c" | grep -qE '^[a-z]+$' || { echo "FATAL: invalid channel '$c'" >&2; exit 1; }
done
[ "$FROM" != "$TO" ] || { echo "FATAL: a channel cannot be promoted onto itself" >&2; exit 1; }
[ -x "$ARCHIVE/publish_archives.sh" ] \
    || { echo "FATAL: no publish_archives.sh in $ARCHIVE" >&2; exit 1; }

# shellcheck source=common.sh
. "$(dirname "$(readlink -f "$0")")/common.sh"
lock_archive
cd "$ARCHIVE"
[ -d lists ] || { echo "FATAL: no lists/ in $ARCHIVE" >&2; exit 1; }

publisher_args
for os in $(for d in $KNOWN_DISTROS; do ubuntu_for "$d"; done | sort -u); do
    routed=0
    for d in $(distros_on "$os"); do
        compgen -G "lists/*-$d.txt" >/dev/null && routed=1
    done
    [ "$routed" = 1 ] || { echo "--- $os: nothing routed - skipping"; continue; }
    echo "--- $os: $FROM -> $TO"
    docker run --rm \
        "${PUBLISHER_ARGS[@]}" \
        -e "OS_VERSION=$os" -e "CHANNEL=$TO" -e "PROMOTE_FROM=$FROM" \
        -e "LIST_DISTROS=$(distros_on "$os")" -e "PROMOTE_ROOTS=${ROOTS:-}" \
        -v "$PWD:/work" -v "$PWD/dist:/dist" \
        "$IMAGE" /work/publish_archives.sh
done
prune_edge_sources
