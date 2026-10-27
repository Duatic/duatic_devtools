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

# Check what publish-gate lets through to add_and_publish.sh: which roots and which distro. Runs the
# real gate beside a stub add_and_publish.sh that reports what it was given.
#
# Usage:  publish_gate_test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$HERE/../archive/publish-gate" "$TMP/publish-gate"
printf '#!/bin/sh\necho "DISTRO=$DISTRO CHANNEL=$CHANNEL SPECS=$*"\n' > "$TMP/add_and_publish.sh"
printf '#!/bin/sh\necho "PROMOTE $1 -> $2 ROOTS=$ROOTS"\n' > "$TMP/promote.sh"
chmod +x "$TMP/publish-gate" "$TMP/add_and_publish.sh" "$TMP/promote.sh"

# request <distro> <spec> [channel]: the request as the publish workflow sends it.
request() {
    printf "EXPECTED_KEY_FPR='0000' DISTRO='%s' CHANNEL='%s' ~/duatic_devtools/packaging/archive/add_and_publish.sh '%s'" \
        "$1" "${3:-stable}" "$2"
}

fail=0
# gate <pass|fail> <description> <expected output> <request> [VAR=value...] -- <permitted roots...>
gate() {
    local want="$1" desc="$2" expected="$3" req="$4" out rc envs=()
    shift 4
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    out="$(env -i PATH="$PATH" "${envs[@]}" SSH_ORIGINAL_COMMAND="$req" "$TMP/publish-gate" "$@" 2>&1)" \
        && rc=0 || rc=$?
    if { { [ "$want" = pass ] && [ "$rc" = 0 ]; } || { [ "$want" = fail ] && [ "$rc" != 0 ]; }; } \
        && printf '%s' "$out" | grep -qF -- "$expected"; then
        echo "    ok    $desc"
    else
        echo "    FAIL  $desc"; printf '%s\n' "$out" | sed 's/^/          /'; fail=1
    fi
}

gate pass "a fixed DISTRO ignores the distro the request names" "DISTRO=jazzy CHANNEL= SPECS=app:public:1.0" \
    "$(request kilted app:public:1.0)" DISTRO=jazzy -- public
gate pass "DISTROS lets the request pick a permitted distro" "DISTRO=kilted CHANNEL= SPECS=app:public:1.0" \
    "$(request kilted app:public:1.0)" "DISTROS=humble jazzy kilted" -- public
gate pass "DISTROS may be comma separated" "DISTRO=humble CHANNEL= SPECS=app:public:1.0" \
    "$(request humble app:public:1.0)" "DISTROS=humble,jazzy" -- public
gate fail "a distro the key was not given" "this key may not publish for 'rolling'" \
    "$(request rolling app:public:1.0)" "DISTROS=humble jazzy" -- public
gate fail "DISTROS and a request naming no distro" "the request names no DISTRO" \
    "~/duatic_devtools/packaging/archive/add_and_publish.sh 'app:public:1.0'" "DISTROS=jazzy" -- public
gate fail "a root the key was not pinned to" "this key may not publish into 'products/a'" \
    "$(request jazzy app:products/a:1.0)" "DISTROS=jazzy" -- public

gate pass "CHANNELS lets the request pick a permitted channel" "DISTRO=jazzy CHANNEL=edge SPECS=app:public:1.0" \
    "$(request jazzy app:public:1.0 edge)" "DISTROS=jazzy" "CHANNELS=stable edge" -- public
gate fail "a channel the key was not given" "this key may not deliver into 'nightly'" \
    "$(request jazzy app:public:1.0 nightly)" "DISTROS=jazzy" "CHANNELS=stable edge" -- public
gate fail "without CHANNELS a request for another channel is refused" "this key delivers into 'stable', not 'edge'" \
    "$(request jazzy app:public:1.0 edge)" "DISTROS=jazzy" -- public
gate pass "without CHANNELS a request for the line's channel goes ahead" "DISTRO=jazzy CHANNEL=edge SPECS=app:public:1.0" \
    "$(request jazzy app:public:1.0 edge)" "DISTROS=jazzy" "CHANNEL=edge" -- public
gate pass "a permitted promotion, in the key's roots" "PROMOTE edge -> nightly ROOTS=public" \
    "PROMOTE='edge:nightly'" "PROMOTIONS=edge:nightly" -- public
gate fail "a promotion the key was not given" "this key may not promote 'edge:stable'" \
    "PROMOTE='edge:stable'" "PROMOTIONS=edge:nightly" -- public
gate fail "no promotion without PROMOTIONS" "this key may not promote 'edge:nightly'" \
    "PROMOTE='edge:nightly'" "DISTROS=jazzy" -- public

exit "$fail"
