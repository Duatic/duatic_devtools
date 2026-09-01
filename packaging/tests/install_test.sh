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

# Install the package from apt on a machine that has never seen the source. Runs inside the
# container; see README.md for the docker command.
#
# Usage:  /tests/install_test.sh [package-name]

set -euo pipefail

REPO="${REPO:-/builder/repo}"
ROS_DISTRO_ARG="${ROS_DISTRO:-jazzy}"
PKG="${1:?usage: install_test.sh <debian package name>}"

[ -f "$REPO/Packages" ] \
    || { echo "FATAL: no index at $REPO. Run make_repo.sh on the host first." >&2; exit 1; }

echo "=============================================================="
echo " installing $PKG from a local apt repository"
echo "=============================================================="

# A mounted source repository would make this test prove less than it appears to.
if [ -d /src ]; then
    echo "WARNING: /src is mounted here, so this is not a clean machine."
else
    echo "--- clean machine: no source mounted"
fi

echo "--- registering the local repository"
echo "deb [trusted=yes] file:$REPO ./" > /etc/apt/sources.list.d/duatic-local.list
apt-get update -qq

echo
echo "--- where apt thinks it comes from"
apt-cache policy "$PKG"

echo
echo "--- installing"
apt-get install -y "$PKG"

echo
echo "--- every Duatic package now installed"
echo "    (more than the one asked for means apt resolved a Duatic dependency by itself)"
dpkg-query -W -f='    ${Package} ${Version}\n' 'ros-*-duatic-*' 2>/dev/null || true

echo
echo "--- installed files (a sample)"
# Not filtered by extension: a content-only package ships no binaries and would look empty.
dpkg -L "$PKG" | grep -vE '^/(opt/ros/[^/]+)?/?$' | grep -E '\.[a-z]+$' | head -15 | sed 's/^/    /'

# Unpacking a package is not the same as ROS being able to load what it ships. Set INTERFACE to
# something the package provides, "my_pkg/srv/MyService", to check that too.
if [ -n "${INTERFACE:-}" ]; then
    echo
    echo "--- functional check: can ROS load $INTERFACE?"
    set +u
    # shellcheck disable=SC1090
    source "/opt/ros/$ROS_DISTRO_ARG/setup.bash"
    set -u
    ros2 interface show "$INTERFACE" | sed 's/^/    /'
fi

echo
echo "=============================================================="
echo " PASS: $PKG installed from apt${INTERFACE:+ and $INTERFACE loads}."
echo "=============================================================="
