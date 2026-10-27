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


# Sourced by add_and_publish.sh and promote.sh.

# The Ubuntu release each ROS distro is built on (REP 2000), which names the suite it lands in.
KNOWN_DISTROS="humble jazzy kilted lyrical rolling"
ubuntu_for() {
    case "$1" in
        humble) echo jammy ;;
        jazzy | kilted) echo noble ;;
        lyrical | rolling) echo resolute ;;
    esac
}
# distros_on <ubuntu>: the known distros built on it, space separated.
distros_on() {
    local d out=""
    for d in $KNOWN_DISTROS; do
        [ "$(ubuntu_for "$d")" = "$1" ] && out="$out $d"
    done
    printf '%s\n' "${out# }"
}

# lock_archive: wait for any other publish or promotion on this archive to finish, then hold the
# archive until this script exits. aptly's database and the routing lists take one writer.
lock_archive() {
    exec 9>"$ARCHIVE/.lock"
    flock -w "${LOCK_WAIT:-1200}" 9 \
        || { echo "FATAL: another publish held the archive for ${LOCK_WAIT:-1200}s" >&2; exit 1; }
}

# The docker run arguments every publisher run needs: the passphrase file, named as the container
# sees it since that is where gpg runs, and the host user to hand files back to.
publisher_args() {
    PUBLISHER_ARGS=(-e "EXPECTED_KEY_FPR=${EXPECTED_KEY_FPR:-}" -e "ALLOW_THROWAWAY_KEY=${ALLOW_THROWAWAY_KEY:-0}")
    if [ -n "${GPG_PASSPHRASE_FILE:-}" ]; then
        PUBLISHER_ARGS+=(-e "GPG_PASSPHRASE_FILE=$GPG_PASSPHRASE_FILE")
    elif [ -f "$ARCHIVE/.passphrase" ]; then
        PUBLISHER_ARGS+=(-e "GPG_PASSPHRASE_FILE=/work/.passphrase")
    fi
    # Rootless docker already maps the container's root onto the invoking user, so the files come
    # back owned correctly and publish_archives.sh skips its hand-back when these are unset. Setting
    # them there would chown into the subordinate range instead, which takes the tree away.
    if ! docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        PUBLISHER_ARGS+=(-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)")
    fi
}

# prune_edge_sources: delete the source tarballs of builds of main that no published index in their
# root lists any more. A binary still served keeps its source; release sources are never removed.
prune_edge_sources() {
    local src tree base pkg ver
    shopt -s nullglob
    for src in dist/public/sources/*/*+git*.src.tar.gz dist/private/*/sources/*/*+git*.src.tar.gz; do
        tree="${src%%/sources/*}"
        base="$(basename "$src" .src.tar.gz)"
        pkg="${base%%_*}"; ver="${base#*_}"
        if ! grep -rqxF "Version: $ver" "$tree/dists" 2>/dev/null; then
            rm -f "$src"
            echo "    - source $pkg $ver"
        fi
    done
    shopt -u nullglob
}
