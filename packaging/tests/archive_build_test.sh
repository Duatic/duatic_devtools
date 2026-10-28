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

# Build duatic_probe_exec with build_pkg.sh against a signed local archive that publishes
# ros-jazzy-duatic-helper-msgs in noble-stable and has no noble-edge suite. Needs docker.
#
# Usage:  archive_build_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker run --rm -i \
    -v "$HERE/../builder:/builder:ro" \
    -v "$HERE/probes:/probes:ro" \
    ros:jazzy-ros-base bash -s <<'INNER'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends gnupg apt-utils dpkg-dev >/dev/null

arch="$(dpkg --print-architecture)"
w=/work
mkdir -p "$w/deb/DEBIAN" "$w/archive/pool" "$w/keys" "$w/archive/dists/noble-stable/main/binary-$arch"
printf 'Package: ros-jazzy-duatic-helper-msgs\nVersion: 1.0.0-0noble\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: test\n' \
    "$arch" > "$w/deb/DEBIAN/control"
dpkg-deb -b "$w/deb" "$w/archive/pool/helper.deb" >/dev/null

export GNUPGHOME="$w/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key "archive <a@example.invalid>" rsa2048 sign 1d 2>/dev/null
gpg --batch --passphrase '' --quick-generate-key "other <o@example.invalid>" rsa2048 sign 1d 2>/dev/null
gpg --export archive > "$w/keys/archive.gpg"
gpg --export other > "$w/keys/other.gpg"
( cd "$w/archive" && apt-ftparchive packages pool > "dists/noble-stable/main/binary-$arch/Packages" )
( cd "$w/archive/dists/noble-stable" \
    && apt-ftparchive -o APT::FTPArchive::Release::Suite=noble-stable \
        -o APT::FTPArchive::Release::Components=main -o APT::FTPArchive::Release::Architectures="$arch" \
        release . > Release \
    && gpg --batch --yes --local-user archive --clearsign -o InRelease Release )

pass=0 fail=0
# check <name> <built|refused> <pattern> <env...>: build_pkg.sh for duatic_probe_exec with <env> ends
# as expected, with a line of its log, or the Depends of the .deb it built, matching the pattern.
check() {
    local name="$1" expect="$2" pattern="$3" got=built; shift 3
    rm -r -f /src /out /etc/apt/sources.list.d/duatic-archive.sources /etc/ros/rosdep/sources.list.d/15-archive.list
    cp -a /probes /src
    mkdir /out
    env "$@" /builder/build_pkg.sh duatic_probe_exec > /tmp/build.log 2>&1 < /dev/null || got=refused
    [ "$got" = refused ] || echo "Depends: $(dpkg-deb -f /out/*.deb Depends)" >> /tmp/build.log
    if [ "$got" = "$expect" ] && grep -qE "$pattern" /tmp/build.log; then
        pass=$((pass + 1)); echo "ok   $name"
    else
        fail=$((fail + 1)); echo "FAIL $name: $got, expected $expect with '$pattern'"
        grep -v '^Skip distro' /tmp/build.log | tail -15
    fi
}

archive=(ARCHIVE_URL="file://$w/archive" ARCHIVE_KEYRING="$w/keys/archive.gpg")
check "a dependency resolves from stable" built "^Depends: .*ros-jazzy-duatic-helper-msgs" "${archive[@]}"
check "a missing edge suite is read as empty" built "noble-edge is not published yet" \
    "${archive[@]}" ARCHIVE_CHANNELS="edge stable"
check "with no suite published, the archive maps nothing" refused "no suite of .* is published yet" \
    "${archive[@]}" ARCHIVE_CHANNELS="edge"
check "a key that did not sign it is refused" refused "NO_PUBKEY|not signed|signature" \
    ARCHIVE_URL="file://$w/archive" ARCHIVE_KEYRING="$w/keys/other.gpg"
check "an archive that cannot be reached is refused" refused "FATAL: http://archive.invalid" \
    ARCHIVE_URL="http://archive.invalid" ARCHIVE_KEYRING="$w/keys/archive.gpg"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
INNER
