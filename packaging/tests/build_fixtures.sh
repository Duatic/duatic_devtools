#!/usr/bin/env bash
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
