#!/usr/bin/env python3
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

"""Run clang-format with the ``.clang-format`` of this repository's revision.

The style is installed together with the hook (see ``data-files`` in pyproject.toml) and used from
there. With ``--install-style-file`` it is also copied into the root of the repository that is being
checked, so that editors and plain ``clang-format`` calls use the very same style.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from importlib.metadata import distribution
from pathlib import Path

# .clang-format file
STYLE = ".clang-format"

# Files that only trigger the hook, so that the style is installed or restored on their change
TRIGGERS = (STYLE, ".pre-commit-config.yaml")

# Without this flag (CLI usage) the style is not installed and an existing .clang-format is used as it is
INSERT_FLAG = "--install-style-file"


def packaged_style() -> Path:
    """Locate the ``.clang-format`` that was installed together with this package.

    :returns: path of the installed file, which is the one of the hook's revision
    """
    dist = distribution("duatic-devtools-hooks")
    entry = next(p for p in dist.files or [] if p.name == STYLE)
    return Path(dist.locate_file(entry))


def main() -> int:
    """Format the given files with the packaged style, installing it into the root if asked to.

    With ``--install-style-file``, the style is put into the working directory (pre-commit runs hooks
    from the repository root). The remaining command line is forwarded to clang-format as files,
    unless they are only triggers.

    :returns: the exit code of clang-format, or 1 if the style was installed or changed, so that
        the user stages it; 2 if clang-format cannot be run (nothing is installed then)
    """
    # The hook environment should provide clang-format
    if shutil.which("clang-format") is None:
        print("SHOULD NOT HAPPEN: clang-format not found on PATH", file=sys.stderr)
        return 2

    changed = False
    style_file = packaged_style()
    if INSERT_FLAG in sys.argv[1:]:
        source = style_file.read_bytes()
        destination = Path.cwd() / STYLE
        if changed := (not destination.is_file() or destination.read_bytes() != source):
            destination.write_bytes(source)

    code = 0
    if sources := [a for a in sys.argv[1:] if a not in (*TRIGGERS, INSERT_FLAG)]:
        # NOTE: This also ignores a repo's nested .clang-format files.
        #       This follows our intent to enforce a common style
        command = [
            "clang-format",
            *sources,
            "-i",
            f"-style=file:{style_file}",
            "-fallback-style=none",
        ]
        code = subprocess.call(command)

    return code or int(changed)


if __name__ == "__main__":
    sys.exit(main())
