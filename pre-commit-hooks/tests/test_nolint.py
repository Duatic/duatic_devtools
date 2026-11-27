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

"""Tests of the `nolint` comments of `check-xacro`: one file with every behaviour at a different
place, and the hard errors that no comment can silence."""

import re

from duatic_xacro_hooks import check_xacro
from duatic_xacro_hooks.format_xacro import format_text

PACKAGE_XML = "<package><name>pkg_a</name></package>\n"


# One formatted file with every `nolint` behaviour at a different place. Each line below names what
# it checks; the findings that must remain are listed in NOLINT_REMAINING.
NOLINT_FILE = """\
<?xml version="1.0"?>
<!-- nolint: mesh-uri, origin-rotation -->
<!-- nolint: header-typo -->
<robot name="r" xmlns:xacro="http://www.ros.org/wiki/xacro">

  <xacro:include filename="lib.xacro"/>  <!-- nolint -->

  <link name="visual_link">
    <visual>
      <geometry>
        <mesh filename="file:///a.stl"/>
      </geometry>
    </visual>
  </link>

  <joint name="rotated" type="fixed">
    <origin rpy="0 0 0" quat_xyzw="0 0 0 1"/>
  </joint>

  <xacro:macro name="all_codes" params="p"/>  <!-- nolint: empty-block, unused-param -->

  <xacro:macro name="one_code" params="p"/>  <!-- nolint: unused-param -->

  <xacro:macro name="unprotected" params=""/>

  <xacro:macro name="unknown_code" params=""/>  <!-- nolint: no-such-code -->

  <xacro:macro name="hard_error" params=""/>  <!-- nolint: parse-error -->

  <xacro:macro name="m" params="">

    <link name="l"/>

  </xacro:macro>

  <xacro:m this_is_a_long_extra_attribute_one="a-value-that-pushes-the-tag-over-the-limit"
           this_is_a_long_extra_attribute_two="another-long-value"/>  <!-- nolint: unknown-param -->

  <link name="formatter_code"/>  <!-- nolint: attribute-order -->

  <!-- nolint: mesh-uri -->
  <link name="misplaced"/>

</robot>
"""

# (text of the line, code) of what the checker still reports
NOLINT_REMAINING = [
    ("header-typo", "nolint-unknown-code"),  # file-level nolint with an unknown code
    ('name="one_code"', "empty-block"),  # a nolint with one of two codes
    ('name="unprotected"', "empty-block"),  # no nolint: the ones above and below do not leak
    ('name="unknown_code"', "empty-block"),  # an unknown code silences nothing
    ('name="unknown_code"', "nolint-unknown-code"),
    ('name="hard_error"', "empty-block"),  # a hard error cannot be silenced, naming one is wrong
    ('name="hard_error"', "nolint-unknown-code"),
    ("<!-- nolint: mesh-uri -->\n  <link", "nolint-placement"),  # a nolint on its own line
]


def reported(text: str, root, capsys) -> list[tuple[int, str]]:
    """Check text as main.xacro and return (line, code) of each finding."""
    root.mkdir()
    package = root / "pkg_a"
    package.mkdir()
    (package / "package.xml").write_text(PACKAGE_XML)
    (package / "main.xacro").write_text(text)
    check_xacro.main([str(package / "main.xacro")])
    lines = capsys.readouterr().out.splitlines()
    return [(int(line.split(":")[1]), line.split(": ")[1]) for line in lines]


def test_nolint_behaviours(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)

    # without any nolint, every fault is reported
    bare = re.sub(r"  <!-- nolint.*?-->|<!-- nolint.*?-->\n", "", NOLINT_FILE)
    faults = {code for _, code in reported(bare, tmp_path / "bare", capsys)}
    assert {"include-without-find", "mesh-uri", "origin-rotation", "empty-block"} <= faults
    assert {"unused-param", "unknown-param"} <= faults

    # with them, exactly NOLINT_REMAINING is left (everything else is silenced by a nolint above
    # the root, a bare or a coded one at a line end, also of a tag over several lines)
    lines = NOLINT_FILE.splitlines()
    expected = sorted(
        (next(n for n, line in enumerate(lines, 1) if text.split("\n")[0] in line), code)
        for text, code in NOLINT_REMAINING
    )
    assert reported(NOLINT_FILE, tmp_path / "full", capsys) == expected

    # the formatter keeps all of it as it is
    formatted, warnings = format_text(NOLINT_FILE)
    assert formatted == NOLINT_FILE and warnings == []


def test_hard_errors_cannot_be_silenced(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    broken = '<?xml version="1.0"?>\n{}<robot name="r">\n<link></robot>\n'
    unbound = '<?xml version="1.0"?>\n{}<robot name="r">\n<xacro:arg name="a"/>  <!-- nolint -->\n</robot>\n'

    for n, (text, code) in enumerate([(broken, "parse-error"), (unbound, "unbound-prefix")]):
        # above the root, and (for the unbound prefix) at the end of the line
        silenced = text.format("<!-- nolint -->\n")
        assert code in [c for _, c in reported(silenced, tmp_path / f"d{n}", capsys)]
