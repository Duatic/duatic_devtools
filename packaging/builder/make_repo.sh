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

# Turn the built packages into a local flat apt repository: a directory with a Packages index.
# Runs on the host. Signing and channels are publish.sh's job.
#
# Usage:  ./make_repo.sh

set -euo pipefail

BUILDER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$BUILDER/out"
REPO="$BUILDER/repo"

# apt-ftparchive rather than dpkg-scanpackages, which globs *.deb only and so omits every
# -dbgsym package, built as .ddeb.
command -v apt-ftparchive >/dev/null \
    || { echo "FATAL: apt-ftparchive missing (apt-get install apt-utils)" >&2; exit 1; }

shopt -s nullglob
pkgs=("$OUT"/*.deb "$OUT"/*.ddeb)
shopt -u nullglob
[ ${#pkgs[@]} -gt 0 ] || { echo "FATAL: no packages in $OUT, run build_pkg.sh first" >&2; exit 1; }

mkdir -p "$REPO"
cp -f "${pkgs[@]}" "$REPO"/

cd "$REPO"
# Every version is indexed, not only the newest: rollback needs prior versions installable.
apt-ftparchive packages . > Packages
gzip -9cf Packages > Packages.gz

indexed="$(grep -c '^Package:' Packages)"
files="$(ls -1 ./*.deb ./*.ddeb 2>/dev/null | wc -l)"
[ "$indexed" = "$files" ] \
    || { echo "FATAL: $files package files but $indexed indexed" >&2; exit 1; }

echo "=============================================================="
echo " local apt repository: $REPO"
echo "=============================================================="
ls -la "$REPO"
echo
echo "--- indexed packages ---"
grep -E '^(Package|Version|Architecture|Filename|Depends):' Packages | sed 's/^/    /'
echo
echo "Consumed with:  deb [trusted=yes] file:$REPO ./"
echo "Next: install_test.sh, in a container that has never seen the source."
