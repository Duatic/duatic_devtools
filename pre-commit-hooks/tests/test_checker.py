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

"""One test per check code of `check-xacro`: `CASES` holds, for every code, a small package whose
`main.xacro` triggers it. Each case is run through the CLI (so includes and `$(find ...)` work)."""

import pytest

from duatic_xacro_hooks import check_xacro
from duatic_xacro_hooks.checks.codes import CODES

XACRO_NS = 'xmlns:xacro="http://www.ros.org/wiki/xacro"'
PACKAGE_XML = "<package><name>pkg_a</name></package>\n"
FIND = "$(find pkg_a)"


def robot(body: str, attrs: str = f'name="r" {XACRO_NS}') -> str:
    """A well-formed top-level file; the body starts in line 3."""
    return f'<?xml version="1.0"?>\n<robot {attrs}>\n{body}\n</robot>\n'


def library(body: str) -> str:
    """A well-formed library (a robot without a name)."""
    return robot(body, XACRO_NS)


def macro(name: str, params: str, body: str = '<link name="l"/>') -> str:
    return f'<xacro:macro name="{name}" params="{params}">\n{body}\n</xacro:macro>'


# code -> files of the package (path -> text), main.xacro is the checked one
CASES: dict[str, dict[str, str]] = {
    # --- hard errors
    "parse-error": {"main.xacro": '<?xml version="1.0"?>\n<robot name="r">\n<link></robot>\n'},
    "unbound-prefix": {
        "main.xacro": '<?xml version="1.0"?>\n<robot name="r">\n<xacro:property name="a" value="1"/>\n</robot>\n'
    },
    # --- xml file
    "xml-declaration": {"main.xacro": f'<robot name="r" {XACRO_NS}>\n<link name="l"/>\n</robot>\n'},
    "xml-encoding": {
        "main.xacro": f'<?xml version="1.0" encoding="ISO-8859-1"?>\n<robot name="r" {XACRO_NS}>\n<link name="l"/>\n</robot>\n'
    },
    "nolint-placement": {
        "main.xacro": robot('<link name="l"/>\n<!-- nolint: mesh-uri -->\n<link name="m"/>')
    },
    "nolint-unknown-code": {"main.xacro": robot('<link name="l"/>  <!-- nolint: no-such-code -->')},
    # --- args and includes
    "arg-placement": {"main.xacro": robot('<link name="l"/>\n<xacro:arg name="a" default="1"/>')},
    "include-without-find": {"main.xacro": robot('<xacro:include filename="lib.xacro"/>')},
    "named-include": {
        "main.xacro": robot(f'<xacro:include filename="{FIND}/top.xacro"/>'),
        "top.xacro": robot('<link name="l"/>'),
    },
    "include-placement": {
        "main.xacro": robot(f'<link name="l"/>\n<xacro:include filename="{FIND}/lib.xacro"/>'),
        "lib.xacro": library(macro("m", "")),
    },
    "library-not-lazy": {"main.xacro": library('<link name="l"/>')},
    # --- properties and params
    "unused-param": {"main.xacro": robot(macro("m", "a"))},
    "duplicate-param": {"main.xacro": robot(macro("m", "a a", '<link name="${a}"/>'))},
    # --- block params
    "block-order": {
        "main.xacro": robot(
            macro("m", "*b a", '<xacro:insert_block name="b"/>\n<link name="${a}"/>')
        )
    },
    "block-default": {"main.xacro": robot(macro("m", "*b:=1", '<xacro:insert_block name="b"/>'))},
    "unused-block": {"main.xacro": robot(macro("m", "*b"))},
    "multi-block-name": {
        "main.xacro": robot(
            macro("m", "**b", '<xacro:insert_block name="b"/>')
            + "\n<xacro:m>\n<wrong/>\n</xacro:m>"
        )
    },
    "unknown-param": {"main.xacro": robot(macro("m", "") + '\n<xacro:m extra="1"/>')},
    "missing-param": {"main.xacro": robot(macro("m", "a", '<link name="${a}"/>') + "\n<xacro:m/>")},
    "extra-block": {"main.xacro": robot(macro("m", "") + "\n<xacro:m>\n<x/>\n</xacro:m>")},
    "missing-block": {
        "main.xacro": robot(macro("m", "*b", '<xacro:insert_block name="b"/>') + "\n<xacro:m/>")
    },
    "missing-multi-block": {
        "main.xacro": robot(macro("m", "**b", '<xacro:insert_block name="b"/>') + "\n<xacro:m/>")
    },
    # --- duplicates and others
    "duplicate-macro": {"main.xacro": robot(macro("m", "") + "\n" + macro("m", ""))},
    "duplicate-property": {
        "main.xacro": robot(
            '<xacro:property name="p" value="1"/>\n<xacro:property name="p" value="2"/>'
        )
    },
    "duplicate-arg": {
        "main.xacro": robot('<xacro:arg name="a" default="1"/>\n<xacro:arg name="a" default="2"/>')
    },
    "duplicate-include": {
        "main.xacro": robot(
            f'<xacro:include filename="{FIND}/lib.xacro"/>\n<xacro:include filename="{FIND}/lib.xacro"/>'
        ),
        "lib.xacro": library(macro("m", "")),
    },
    "empty-block": {
        "main.xacro": robot(
            '<xacro:macro name="m" params=""/>\n<xacro:if value="1"><!-- nothing --></xacro:if>'
        )
    },
    "mesh-uri": {
        "main.xacro": robot(
            '<link name="l"><visual><geometry><mesh filename="file:///a.stl"/></geometry></visual></link>'
        )
    },
    "origin-rotation": {
        "main.xacro": robot(
            '<link name="l"/>\n<joint name="j" type="fixed"><origin rpy="0 0 0" quat_xyzw="0 0 0 1"/></joint>'
        )
    },
}


def run_case(files: dict[str, str], root, capsys, *options: str) -> list[str]:
    """Write the package, check its main.xacro and return the reported codes.

    :param files: path -> text of the files of the package
    :param root: directory to write the package to
    :param capsys: pytest output capture
    :param options: more command line options
    :returns: the codes of the reported issues, in order
    """
    package = root / "pkg_a"
    package.mkdir()
    (package / "package.xml").write_text(PACKAGE_XML)
    for rel, text in files.items():
        (package / rel).write_text(text)

    check_xacro.main([*options, str(package / "main.xacro")])
    lines = capsys.readouterr().out.splitlines()
    return [line.split(": ")[1] for line in lines if ": " in line]


def test_every_code_has_a_case():
    assert set(CASES) == set(CODES)


@pytest.mark.parametrize("code", sorted(CODES))
def test_code_is_reported(code, tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    codes = run_case(CASES[code], tmp_path, capsys)
    assert code in codes, f"{code} not reported, got {codes}"


@pytest.mark.parametrize("code", sorted(set(CODES) - {"parse-error", "unbound-prefix"}))
def test_code_can_be_disabled(code, tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    codes = run_case(CASES[code], tmp_path, capsys, "--disable", code)
    assert code not in codes


def test_robot_with_only_comments_is_an_empty_block(tmp_path, monkeypatch, capsys):
    monkeypatch.chdir(tmp_path)
    files = {"main.xacro": robot("<!-- nothing yet -->")}
    assert run_case(files, tmp_path, capsys) == ["empty-block"]
