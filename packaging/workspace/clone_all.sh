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
SENTINEL="no-push://push-disabled.invalid"
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
