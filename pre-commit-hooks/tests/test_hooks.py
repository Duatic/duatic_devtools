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

"""Smoke tests of `format-xacro` and `check-xacro`: run each hook on a valid file, separately,
once on the fixture (`valid.xacro`) and once on a fresh file written by the test."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

HOOKS_DIR = Path(__file__).resolve().parent.parent  # contains the duatic_xacro_hooks package
FIXTURE = Path(__file__).resolve().parent / "valid.xacro"

# valid, but not formatted
FRESH = (
    '<?xml version="1.0"?>\n'
    '<robot name="fresh" xmlns:xacro="http://www.ros.org/wiki/xacro">\n'
    '<link name="a"/>\n'
    '<joint name="j" type="fixed"><parent link="a"/><child link="b"/></joint>\n'
    "</robot>\n"
)


def run_hook(module: str, path: Path) -> subprocess.CompletedProcess[str]:
    """Run `python -m duatic_xacro_hooks.<module> <path>` the way the hook entry does.

    :param module: `format_xacro` or `check_xacro`
    :param path: the file
    :returns: the finished process, with its output as text
    """
    env = {**os.environ, "PYTHONPATH": str(HOOKS_DIR)}
    return subprocess.run(
        [sys.executable, "-m", f"duatic_xacro_hooks.{module}", str(path)],
        capture_output=True,
        text=True,
        env=env,
    )


def test_format_keeps_the_valid_fixture_unchanged(tmp_path):
    copy = tmp_path / "valid.xacro"
    shutil.copy(FIXTURE, copy)

    result = run_hook("format_xacro", copy)

    assert result.returncode == 0 and result.stdout == "" and result.stderr == ""
    assert copy.read_text() == FIXTURE.read_text()


def test_check_accepts_the_valid_fixture():
    result = run_hook("check_xacro", FIXTURE)

    assert result.returncode == 0 and result.stdout == ""


def test_format_a_fresh_file(tmp_path):
    fresh = tmp_path / "fresh.xacro"
    fresh.write_text(FRESH)

    assert run_hook("format_xacro", fresh).returncode == 0
    formatted = fresh.read_text()
    assert formatted != FRESH and '\n  <link name="a"/>\n' in formatted

    # a second run has nothing left to do
    assert run_hook("format_xacro", fresh).returncode == 0
    assert fresh.read_text() == formatted


def test_check_a_fresh_file(tmp_path):
    fresh = tmp_path / "fresh.xacro"
    fresh.write_text(FRESH)

    result = run_hook("check_xacro", fresh)

    assert result.returncode == 0 and result.stdout == ""
