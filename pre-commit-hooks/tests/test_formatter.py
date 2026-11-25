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

"""Golden-file test of `format-xacro`: every `format_cases/NAME.xacro.in` is formatted and compared
with `format_cases/NAME.xacro.out`. The cases are the tricky inputs of the formatter docs (where it
differs from `xmllint --format`: non-ASCII, CDATA, entities, comments, wrapping, ...)."""

from pathlib import Path

from duatic_xacro_hooks import format_xacro

CASES = Path(__file__).resolve().parent / "format_cases"


def run_formatter(name: str, src: bytes, work: Path) -> bytes:
    """Format `src` the way the hook does (on a file) and return the result.

    :param name: name of the case, selects the options
    :param src: bytes of the file
    :param work: scratch directory
    :returns: bytes of the file after formatting
    """
    path = work / f"{name}.xacro"
    path.write_bytes(src)
    options = ["--indent-type", "tab"] if name == "tabs_and_indent" else []
    assert format_xacro.main([str(path), *options]) == 0, name
    return path.read_bytes()


def test_formatted_cases_match_their_expected_output(tmp_path):
    inputs = sorted(CASES.glob("*.xacro.in"))
    assert 0 < len(inputs) <= 30

    failures = []
    for path in inputs:
        name = path.name.removesuffix(".xacro.in")
        src = path.read_bytes()
        if "crlf" in name:  # stored with LF (git may convert line endings), formatted with CRLF
            src = src.replace(b"\n", b"\r\n")
        expected = (CASES / f"{name}.xacro.out").read_bytes()
        scratch = tmp_path / name
        scratch.mkdir()

        formatted = run_formatter(name, src, scratch)
        if formatted != expected:
            failures.append(f"{name}: output differs from {name}.xacro.out")
        elif run_formatter(name, formatted, scratch) != formatted:  # formatting is stable
            failures.append(f"{name}: formatting its own output changes it")

    assert not failures, "\n".join(failures)


def test_every_expected_output_has_an_input():
    inputs = {p.name.removesuffix(".xacro.in") for p in CASES.glob("*.xacro.in")}
    outputs = {p.name.removesuffix(".xacro.out") for p in CASES.glob("*.xacro.out")}
    assert inputs == outputs
