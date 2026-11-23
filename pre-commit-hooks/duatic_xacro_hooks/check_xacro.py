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

"""`check-xacro`: checks xacro files. Command line and the checks in their order."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import TYPE_CHECKING

from duatic_xacro_hooks.checks.codes import CODES, HARD_ERRORS
from duatic_xacro_hooks.checks.includes import IncludeIndex, find_packages
from duatic_xacro_hooks.checks.macros import (
    check_blocks,
    check_duplicates,
    check_empty_macros,
    check_calls,
    collect_macros,
    load_registry,
)
from duatic_xacro_hooks.checks.model import Issue
from duatic_xacro_hooks.checks.names import check_args, check_unused_params
from duatic_xacro_hooks.checks.source import (
    check_declaration,
    check_include_find,
    check_include_placement,
    check_library,
    check_mesh_uris,
    check_origins,
    collect_directives,
    parse_strict,
)
from duatic_xacro_hooks.common import UnreadableFile, display_path, read_utf8, suppresses

if TYPE_CHECKING:
    from collections.abc import Sequence

    from duatic_xacro_hooks.checks.model import Registry


def check_text(
    text: str,
    disable: Sequence[str] = (),
    macros: Registry | None = None,
    path: str = "",
    brought: Sequence[tuple[int, str, Registry]] = (),
    extra: Sequence[Issue] = (),
) -> list[Issue]:
    """Run all checks on the text of one xacro file.

    :param text: content of the file
    :param disable: codes of the checks to skip
    :param macros: macro definitions of other files (see `load_registry`), used to check macro calls
    :param path: name of the file, stored in the macro definitions
    :param brought: (line, filename, macros) of each include of the file, used to find duplicate macros
    :param extra: issues found outside of the text (e.g. in the files it includes), still subject to `nolint` and `disable`
    :returns: the issues, sorted by line and code
    """
    root, errors = parse_strict(text)
    if root is None:
        return errors  # nothing else can be checked, and these can not be silenced

    # macros of this file plus those of the other files, and the nolint comments
    registry = collect_macros(root, {k: list(v) for k, v in (macros or {}).items()}, path)
    file_level, per_line, comment_issues = collect_directives(root, text.splitlines())

    issues = (
        comment_issues
        + list(extra)
        + check_declaration(text)
        + (
            check_args(root)
            + check_blocks(root, registry)
            + check_include_find(root)
            + check_include_placement(root)
            + check_library(root)
            + check_mesh_uris(root)
            + check_origins(root)
            + check_empty_macros(root)
            + check_unused_params(root, registry)
            + check_calls(root, registry)
            + check_duplicates(root, brought, path)
        )
    )

    def silenced(issue: Issue) -> bool:
        """Is the issue silenced by a file-level or a line-level `nolint`?

        :param issue: the issue to test
        :returns: True if it is silenced
        """
        return any(
            suppresses(codes, issue.code) for codes in file_level + per_line.get(issue.line, [])
        )

    # drop disabled and silenced issues
    return sorted(
        (i for i in issues if i.code not in disable and not silenced(i)),
        key=lambda i: (i.line, i.code),
    )


def build_parser() -> argparse.ArgumentParser:
    """Command line parser of `check-xacro`.

    :returns: the parser
    """
    parser = argparse.ArgumentParser(
        prog="check-xacro",
        description="Check xacro files. Exit code 1 if anything was found. See --list-codes.",
    )
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument(
        "--disable",
        action="append",
        default=[],
        choices=sorted(set(CODES) - HARD_ERRORS),
        metavar="CODE",
        help="do not report this check (repeat for several)",
    )
    parser.add_argument("--list-codes", action="store_true", help="print all check codes and exit")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point of `check-xacro`.

    :param argv: arguments (default: `sys.argv`)
    :returns: exit code: 1 if anything was reported, else 0
    """
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.list_codes:
        for code, desc in CODES.items():
            print(f"{code:26} {desc}")
        return 0
    if not args.files:
        parser.error("no files given")

    # the packages below the current directory (the repository root under pre-commit) and the
    # package that contains each checked file: the nearest parent directory with a package.xml
    cwd = Path.cwd()
    own = [
        next((p for p in f.resolve().parents if (p / "package.xml").is_file()), None)
        for f in args.files
    ]
    includes = IncludeIndex(find_packages([cwd, *(d for d in own if d is not None)]))

    found = 0
    for path in args.files:
        # an unreadable file counts as a finding, the others are still checked
        try:
            _, text = read_utf8(path)
        except UnreadableFile as e:
            print(f"{display_path(path)}:1: parse-error: {e}")
            found += 1
            continue

        registry = includes.registry_of(path)

        for issue in check_text(
            text,
            args.disable,
            registry,
            includes.uri(path),
            includes.brought_macros(path),
            includes.named_includes(path) + includes.duplicates(path),
        ):
            print(f"{display_path(path)}:{issue.line}: {issue.code}: {issue.message}")
            found += 1
    return 1 if found else 0


__all__: list[str] = ["CODES", "check_text", "load_registry", "main"]


if __name__ == "__main__":
    sys.exit(main())
