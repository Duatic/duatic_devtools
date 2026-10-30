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
# ros-jazzy-duatic-helper-msgs in noble-stable and has no noble-edge suite, and against a root
# served only to a client certificate that publishes it beside an open root that does not.
# Needs docker.
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
apt-get update -qq && apt-get install -y -qq --no-install-recommends gnupg apt-utils dpkg-dev openssl ca-certificates >/dev/null

arch="$(dpkg --print-architecture)"
w=/work
mkdir -p "$w/keys"
export GNUPGHOME="$w/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key "archive <a@example.invalid>" rsa2048 sign 1d 2>/dev/null
gpg --batch --passphrase '' --quick-generate-key "other <o@example.invalid>" rsa2048 sign 1d 2>/dev/null
gpg --export archive > "$w/keys/archive.gpg"
gpg --export other > "$w/keys/other.gpg"

# root <dir> <package>: a signed archive root at <dir> publishing <package> in noble-stable
root() {
    local dir="$1" pkg="$2"
    mkdir -p "$w/deb-$pkg/DEBIAN" "$dir/pool" "$dir/dists/noble-stable/main/binary-$arch"
    printf 'Package: %s\nVersion: 1.0.0-0noble\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: test\n' \
        "$pkg" "$arch" > "$w/deb-$pkg/DEBIAN/control"
    dpkg-deb -b "$w/deb-$pkg" "$dir/pool/$pkg.deb" >/dev/null
    ( cd "$dir" && apt-ftparchive packages pool > "dists/noble-stable/main/binary-$arch/Packages" )
    ( cd "$dir/dists/noble-stable" \
        && apt-ftparchive -o APT::FTPArchive::Release::Suite=noble-stable \
            -o APT::FTPArchive::Release::Components=main -o APT::FTPArchive::Release::Architectures="$arch" \
            release . > Release \
        && gpg --batch --yes --local-user archive --clearsign -o InRelease Release )
}
root "$w/archive" ros-jazzy-duatic-helper-msgs
root "$w/open" ros-jazzy-duatic-unrelated
root "$w/gated" ros-jazzy-duatic-helper-msgs

# The gated root, served over https by a server its CA vouches for, to a client certificate from
# the same CA, and answering 403 to a request without one.
pki=/tmp/pki
mkdir -p "$pki"
ec=(-newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes)
openssl req -x509 "${ec[@]}" -keyout "$pki/ca.key" -out "$pki/ca.crt" -subj /CN=ca -days 1 2>/dev/null
# sign <name> <subject> [extfile]: a certificate for <name> from the CA
sign() {
    openssl req "${ec[@]}" -keyout "$pki/$1.key" -out "$pki/$1.csr" -subj "$2" 2>/dev/null
    openssl x509 -req -in "$pki/$1.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" -CAcreateserial \
        -out "$pki/$1.crt" -days 1 ${3:+-extfile "$3"} 2>/dev/null
}
printf 'subjectAltName=IP:127.0.0.1\n' > "$pki/server.ext"
sign server /CN=127.0.0.1 "$pki/server.ext"
sign client /CN=ci
openssl req -x509 "${ec[@]}" -keyout "$w/keys/rogue.key" -out "$w/keys/rogue.crt" -subj /CN=rogue -days 1 2>/dev/null
cp "$pki/client.crt" "$pki/client.key" "$w/keys/"
cp "$pki/ca.crt" /usr/local/share/ca-certificates/archive-test-ca.crt
update-ca-certificates >/dev/null 2>&1
cat > /tmp/serve.py <<PY
import functools, http.server, ssl
class Gate(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if not self.connection.getpeercert():
            self.send_response(403)
            self.end_headers()
            return
        super().do_GET()
    def log_message(self, *args):
        pass
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain("$pki/server.crt", "$pki/server.key")
tls.load_verify_locations("$pki/ca.crt")
tls.verify_mode = ssl.CERT_OPTIONAL
server = http.server.ThreadingHTTPServer(("127.0.0.1", 8443), functools.partial(Gate, directory="$w/gated"))
server.socket = tls.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
python3 /tmp/serve.py &
gated=https://127.0.0.1:8443
secret="$(sed -n 2p "$w/keys/client.key")"

pass=0 fail=0
# check <name> <built|refused> <pattern> <env...>: build_pkg.sh for duatic_probe_exec with <env> ends
# as expected, with a line of its log, or the Depends of the .deb it built, matching the pattern,
# and the client key appears in neither the log, the source nor the output.
check() {
    local name="$1" expect="$2" pattern="$3" got=built; shift 3
    rm -r -f /src /out /etc/apt/sources.list.d/duatic-archive.sources /etc/ros/rosdep/sources.list.d/15-archive.list \
        /etc/apt/apt.conf.d/90duatic-client /etc/apt/duatic-client
    cp -a /probes /src
    mkdir /out
    env "$@" /builder/build_pkg.sh duatic_probe_exec > /tmp/build.log 2>&1 < /dev/null || got=refused
    [ "$got" = refused ] || echo "Depends: $(dpkg-deb -f /out/*.deb Depends)" >> /tmp/build.log
    if grep -rqF "$secret" /tmp/build.log /src /out; then
        fail=$((fail + 1)); echo "FAIL $name: the client key leaked"
        grep -rlF "$secret" /tmp/build.log /src /out
    elif [ "$got" = "$expect" ] && grep -qE "$pattern" /tmp/build.log; then
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

keyring=(ARCHIVE_KEYRING="$w/keys/archive.gpg")
cert=(ARCHIVE_CLIENT_CERT="$w/keys/client.crt" ARCHIVE_CLIENT_KEY="$w/keys/client.key")
check "a dependency resolves from a gated root listed first" built "^Depends: .*ros-jazzy-duatic-helper-msgs" \
    ARCHIVE_URL="$gated file://$w/open" "${cert[@]}" "${keyring[@]}"
check "a dependency resolves from a gated root listed last" built "^Depends: .*ros-jazzy-duatic-helper-msgs" \
    ARCHIVE_URL="file://$w/open $gated" "${cert[@]}" "${keyring[@]}"
check "a missing edge suite of a gated root is read as empty" built "$gated: noble-edge is not published yet" \
    ARCHIVE_URL="$gated" "${cert[@]}" "${keyring[@]}" ARCHIVE_CHANNELS="edge stable"
check "a gated root without a client certificate is refused" refused \
    "FATAL: $gated/dists/noble-stable/InRelease: .*403" ARCHIVE_URL="file://$w/open $gated" "${keyring[@]}"
check "a gated root with a certificate from another CA is refused" refused "FATAL: $gated/dists/noble-stable/InRelease" \
    ARCHIVE_URL="file://$w/open $gated" ARCHIVE_CLIENT_CERT="$w/keys/rogue.crt" \
    ARCHIVE_CLIENT_KEY="$w/keys/rogue.key" "${keyring[@]}"
check "a client certificate without its key is refused" refused "FATAL: ARCHIVE_CLIENT_CERT and ARCHIVE_CLIENT_KEY" \
    ARCHIVE_URL="$gated" ARCHIVE_CLIENT_CERT="$w/keys/client.crt" "${keyring[@]}"
check "a client key that is not there is refused" refused "FATAL: ARCHIVE_CLIENT_KEY=" \
    ARCHIVE_URL="$gated" ARCHIVE_CLIENT_CERT="$w/keys/client.crt" ARCHIVE_CLIENT_KEY="$w/keys/missing.key" \
    "${keyring[@]}"
check "credentials in a URL are refused" refused "FATAL: ARCHIVE_URL holds credentials" \
    ARCHIVE_URL="file://$w/open https://ci:x@127.0.0.1:8443" "${keyring[@]}"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
INNER
