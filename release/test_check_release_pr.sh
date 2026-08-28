#!/usr/bin/env bash
# Drive check_release_pr.py through every case it exists to catch, in a throwaway repository.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check_release_pr.py"
WORK="$(mktemp -d)"
trap 'rm -r "$WORK" 2>/dev/null' EXIT
pass=0; fail=0

check() {  # check <want-exit> <label> <title>
    local want="$1" label="$2" title="$3" got
    ( cd "$WORK" && python3 "$CHECK" --base main --head HEAD --title "$title" ) >/tmp/chk.out 2>&1
    got=$?
    if [ "$got" = "$want" ]; then printf '  PASS  %-56s exit %s\n' "$label" "$got"; pass=$((pass+1))
    else printf '  FAIL  %-56s exit %s want %s\n' "$label" "$got" "$want"; fail=$((fail+1))
         sed 's/^/          /' /tmp/chk.out; fi
}

pkg() {
    mkdir -p "$WORK/$1"
    cat > "$WORK/$1/package.xml" <<EOF
<?xml version="1.0"?>
<package format="3">
  <name>$(basename "$1")</name>
  <version>$2</version>
  <description>test</description>
  <maintainer email="t@duatic.invalid">t</maintainer>
  <license>BSD-3-Clause</license>
</package>
EOF
}
changelog() {
    { printf '^^^^^^^^^^\nChangelog\n^^^^^^^^^^\n\n'
      if [ -n "${2:-}" ]; then
          printf '%s\n%s\n\n* something\n\n' "$2" "$(printf '%*s' ${#2} '' | tr ' ' '-')"
      fi
      printf 'Forthcoming\n-----------\n* work in progress\n'; } > "$WORK/$1/CHANGELOG.rst"
}

cd "$WORK"
git init -q -b main . && git config user.email t@duatic.invalid && git config user.name t
pkg pkg_a 1.0.0; changelog pkg_a "1.0.0 (2026-01-01)"
git add -A && git commit -qm baseline

echo "=== a version bumped without a release title is still a release ==="
git checkout -qb b1
pkg pkg_a 1.1.0; changelog pkg_a "1.1.0 (2026-08-27)"
git commit -qam "feat: something"
check 1 "bump titled as a feature" "feat: something"
check 0 "the same bump titled as a release" "release: pkg_a 1.1.0"

echo "=== a release title with nothing bumped releases nothing ==="
git checkout -q main && git checkout -qb b2
echo "note" > pkg_a/README.md
git add -A && git commit -qm docs
check 1 "release title, no version change" "release: pkg_a"
check 0 "ordinary work, no version change" "docs: tidy the readme"

echo "=== a bump has to be reflected in the changelog ==="
git checkout -q main && git checkout -qb b3
pkg pkg_a 1.2.0
git commit -qam "release: pkg_a 1.2.0"
check 1 "bumped, changelog still says Forthcoming" "release: pkg_a 1.2.0"

echo "=== and the version has to move forward ==="
git checkout -q main && git checkout -qb b4
pkg pkg_a 0.9.0; changelog pkg_a "0.9.0 (2026-08-27)"
git commit -qam "release: downgrade"
check 1 "version going backwards" "release: pkg_a 0.9.0"

echo "=== several packages release independently ==="
git checkout -q main && git checkout -qb b5
pkg pkg_b 0.1.0; changelog pkg_b "0.1.0 (2026-08-27)"
git add -A && git commit -qm "add pkg_b"
pkg pkg_a 1.3.0; changelog pkg_a "1.3.0 (2026-08-27)"
git commit -qam "release: both"
check 0 "two packages in one release PR" "release: pkg_a 1.3.0 and pkg_b 0.1.0"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
