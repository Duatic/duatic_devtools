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

# Assert that nothing in src/ can write to GitHub. Run before and after any release work.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENTINEL="no-push://push-disabled.invalid"
bad=0; n=0

# The visibility column decides how a repository is cloned and, more importantly, whether the
# leak check below applies to it. A typo silently exempts a repository from that check, so the
# column is validated against GitHub rather than trusted. Unauthenticated: 200 is public, 404 is
# private or absent, and either mismatch is a misconfiguration worth stopping for.
if [ -f "$HERE/repos.txt" ] && [ "${NETWORK:-1}" = "1" ]; then
    probed=0; unreachable=0
    # Unauthenticated the API allows 60 requests an hour, which one run of this can exhaust.
    AUTH_HDR=()
    [ -n "${GITHUB_TOKEN:-}" ] && AUTH_HDR=(-H "Authorization: Bearer $GITHUB_TOKEN")
    while read -r vis name url; do
        case "${vis:-}" in ""|\#*) continue ;; esac
        case "$vis" in
            PUBLIC|PRIVATE) ;;
            *) printf '  BADVIS  %-24s visibility is "%s", expected PUBLIC or PRIVATE\n' "$name" "$vis"
               bad=$((bad+1)); continue ;;
        esac
        slug="$(printf '%s' "$url" | sed -e 's#^.*github\.com[:/]##' -e 's#\.git$##')"
        case "$slug" in */*) ;; *) continue ;; esac      # not a GitHub URL, nothing to probe
        body="$(curl -s --max-time 10 -w '\n%{http_code}' "${AUTH_HDR[@]}" \
                "https://api.github.com/repos/$slug" 2>/dev/null || printf '\n000')"
        code="${body##*$'\n'}"
        case "$code" in
            000|403|429) unreachable=$((unreachable+1)); continue ;;   # offline, or rate limited
        esac
        probed=$((probed+1))
        # With a token the API says outright whether a repository is private, which also tells a
        # private repository apart from one that does not exist. Without one, 200 means public and
        # 404 means either.
        if [ -n "${GITHUB_TOKEN:-}" ] && [ "$code" = "200" ]; then
            case "$body" in *'"private": true'*|*'"private":true'*) actual=PRIVATE ;; *) actual=PUBLIC ;; esac
        elif [ "$code" = "200" ]; then
            actual=PUBLIC
        else
            actual=ABSENT
        fi
        if [ "$vis" = "PUBLIC" ] && [ "$actual" != "PUBLIC" ]; then
            printf '  MISMATCH %-23s declared PUBLIC, GitHub says %s (http %s)\n' "$name" "$actual" "$code"
            bad=$((bad+1))
        elif [ "$vis" = "PRIVATE" ] && [ "$actual" = "PUBLIC" ]; then
            printf '  MISMATCH %-23s declared PRIVATE, but it is public\n' "$name"
            bad=$((bad+1))
        fi
    done < "$HERE/repos.txt"
    if [ "$unreachable" -gt 0 ]; then
        printf '  SKIPPED  visibility unverified for %s of %s repositories (offline or rate limited)\n' \
            "$unreachable" "$((probed + unreachable))"
    fi
fi

# A private repository in src/ is legitimate now: the licensed products are built from them. What
# must never happen is one of their packages reaching the public archive root, which is served to
# anyone. Checked against the lists gen_release_set.sh produces, which is where the decision lands.
PUB_LIST_DIR="$HERE/../archive/lists"
if [ -f "$HERE/repos.txt" ] && [ -d "$PUB_LIST_DIR" ]; then
    while read -r vis name _; do
        [ "${vis:-}" = "PRIVATE" ] || continue
        [ -d "$HERE/src/$name" ] || continue
        while read -r px; do
            pkg="$(sed -n 's:.*<name>\(.*\)</name>.*:\1:p' "$px" | head -1)"
            [ -n "$pkg" ] || continue
            deb="ros-[a-z]*-$(echo "$pkg" | tr '_' '-')"
            if grep -qE "^${deb}$" "$PUB_LIST_DIR"/public-*.txt 2>/dev/null; then
                printf '  LEAK    %-24s %s is routed to the public archive\n' "$name" "$pkg"
                bad=$((bad+1))
            fi
        done < <(find "$HERE/src/$name" -name package.xml -not -path '*/.git/*')
    done < "$HERE/repos.txt"
fi

# A package that declares no archive root is withheld rather than published. Loud, because it is
# usually an oversight in a release PR and the package silently does not ship.
for f in "$PUB_LIST_DIR"/unrouted-*.txt; do
    [ -f "$f" ] || continue
    n=$(grep -cv '^#' "$f")
    printf '  UNROUTED %s packages in %s declare no <duatic_archive_root>\n' "$n" "$(basename "$f")"
done

# Nested clones too: a vendored source arrives as its own repository.
for g in $(find "$HERE/src" -name .git -maxdepth 4 -prune | sort); do
    [ -d "$g" ] || continue
    d="$(dirname "$g")"; name="${d#$HERE/src/}"; n=$((n+1))
    fetch="$(git -C "$d" config --get remote.origin.url || echo MISSING)"
    push="$(git -C "$d" config --get remote.origin.pushurl || echo MISSING)"
    hooks="$(git -C "$d" config --get core.hooksPath || echo MISSING)"
    ahead="$(git -C "$d" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
    # Baseline records the tags that arrived with the clone; only tags added since count.
    base="$d/.git/isolation-baseline-tags"
    [ -f "$base" ] || git -C "$d" tag | sort > "$base"
    newtags="$(git -C "$d" tag | sort | comm -13 "$base" - | wc -l)"
    problems=""
    # Release work is working-tree only: nothing committed, nothing tagged.
    [ "$ahead" = "0" ] || problems="$problems commits_ahead=$ahead"
    [ "$newtags" = "0" ] || problems="$problems new_tags=$newtags"
    [ "$push" = "$SENTINEL" ] || problems="$problems pushurl=$push"
    [ "$hooks" = "/dev/null" ] || problems="$problems hooks=$hooks"
    # An SSH origin would carry push capability through the agent whatever pushurl says.
    case "$fetch" in https://*) ;; *) problems="$problems origin=$fetch" ;; esac
    if [ -n "$problems" ]; then
        printf '  UNSAFE  %-24s%s\n' "$name" "$problems"; bad=$((bad+1))
    else
        dirty="$(git -C "$d" status --porcelain | wc -l)"
        printf '  ok      %-24s clean history, %s edited file(s)\n' "$name" "$dirty"
    fi
done
echo
[ "$bad" -eq 0 ] && echo "  $n repositories, all push-disabled" || echo "  $bad UNSAFE"
[ "$bad" -eq 0 ]
