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

# Build every archive fixture into a .deb, reusing the builder unchanged.
# Runs the container itself, so run this in a foreground terminal.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDER="${BUILDER:-$HERE/../builder}"
ROS_DISTRO_TARGET="${ROS_DISTRO_TARGET:-jazzy}"
OS_VERSION="${OS_VERSION:-noble}"
BUILD_IMAGE="${BUILD_IMAGE:-ros:${ROS_DISTRO_TARGET}-ros-base}"
OUT="$HERE/out"
mkdir -p "$OUT"

[ -x "$BUILDER/build_pkg.sh" ] || { echo "FATAL: no build_pkg.sh at $BUILDER" >&2; exit 1; }

# No ordering constraint: every dependency here is runtime-only.
for d in "$HERE"/fixtures/*/; do
    pkg="$(basename "$d")"
    echo "=============================================================="
    echo " $pkg"
    echo "=============================================================="
    docker run --rm -i \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -e ROSDEP_YAML="/rosdep/duatic-fixtures-${ROS_DISTRO_TARGET}.yaml" \
        -e ROS_DISTRO="$ROS_DISTRO_TARGET" \
        -e OS_VERSION="$OS_VERSION" \
        -v "$HERE/fixtures:/src" \
        -v "$BUILDER:/builder" \
        -v "$HERE/rosdep:/rosdep" \
        -v "$OUT:/out" \
        "$BUILD_IMAGE" \
        /builder/build_pkg.sh "$pkg" < /dev/null
done

echo
echo "built into $OUT:"
ls -1 "$OUT" | sed 's/^/  /'
