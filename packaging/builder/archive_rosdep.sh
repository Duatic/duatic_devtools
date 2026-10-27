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

# Print a rosdep mapping for the dependencies of one package that an apt archive publishes: each
# dependency whose ROS Debian name is in the given Packages indexes maps to that name.
#
# Usage:  archive_rosdep.sh <package.xml> <ros distro> <ubuntu release> <Packages file>...

set -euo pipefail

[ $# -ge 4 ] || { echo "usage: archive_rosdep.sh <package.xml> <ros distro> <ubuntu release> <Packages file>..." >&2; exit 2; }

python3 - "$@" <<'PY'
import sys, xml.etree.ElementTree as ET

package_xml, distro, ubuntu, indexes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
kinds = ('depend', 'build_depend', 'buildtool_depend', 'build_export_depend',
         'buildtool_export_depend', 'exec_depend', 'run_depend', 'test_depend', 'doc_depend')
root = ET.parse(package_xml).getroot()
deps = {(e.text or '').strip() for k in kinds for e in root.findall(k)} - {''}

published = set()
for path in indexes:
    with open(path) as f:
        published.update(l.split(':', 1)[1].strip() for l in f if l.startswith('Package:'))

mapped = {d: f"ros-{distro}-{d.replace('_', '-')}" for d in sorted(deps)}
mapped = {d: deb for d, deb in mapped.items() if deb in published}
if not mapped:
    print('{}')
for d, deb in mapped.items():
    print(f'{d}:\n  ubuntu:\n    {ubuntu}: [{deb}]')
PY
