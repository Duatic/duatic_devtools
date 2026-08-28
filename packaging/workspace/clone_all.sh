#!/usr/bin/env bash
# Clone the release set into src/, from repos.txt.
#
#   <visibility> <name> <clone url>
#
# PUBLIC repositories are cloned anonymously, with global and system git config disabled: a
# url.insteadOf rewrite would turn an anonymous HTTPS fetch into an authenticated SSH one carrying
# push rights. PRIVATE ones need a credential, so that config has to stay, and they are cloned only
# with PRIVATE=1.
#
# Every clone gets remote.origin.pushurl set to an unroutable sentinel and core.hooksPath emptied,
# private ones included. Read access differs; write access is refused throughout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENTINEL="no-push://local-release-poc.invalid"
LIST="${LIST:-$HERE/repos.txt}"

[ -f "$LIST" ] || { echo "FATAL: no $LIST. Copy repos.txt.example and edit it." >&2; exit 1; }

anon() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
         GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git "$@"; }
auth() { GIT_TERMINAL_PROMPT=0 git "$@"; }

ok=0; failed=0; skipped=0
while read -r vis name url; do
    case "${vis:-}" in ""|\#*) continue ;; esac
    case "$vis" in
        PUBLIC)  how=anon ;;
        PRIVATE) [ "${PRIVATE:-0}" = "1" ] || { skipped=$((skipped+1)); continue; }; how=auth ;;
        *) echo "FATAL: $name has visibility '$vis', expected PUBLIC or PRIVATE" >&2; exit 1 ;;
    esac
    dest="$HERE/src/$name"
    if [ -d "$dest/.git" ]; then
        echo "  = $name"
    else
        echo "  + $name  ($vis)"
        "$how" clone --quiet "$url" "$dest" || {
            echo "    !! clone failed"; failed=$((failed+1)); continue; }
    fi
    git -C "$dest" config remote.origin.pushurl "$SENTINEL"
    git -C "$dest" config core.hooksPath /dev/null
    ok=$((ok+1))
done < "$LIST"

echo
echo "  $ok cloned or present, $failed failed"
[ "$skipped" -gt 0 ] && echo "  $skipped private repositories skipped. PRIVATE=1 to include them."
echo "  run ./verify_isolation.sh before doing anything else"
