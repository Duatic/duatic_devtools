#!/usr/bin/env bash
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
