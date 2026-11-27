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

"""`format-xacro`: formats xacro files. Command line and the steps in their order."""

import argparse
import re
import sys
from pathlib import Path

from duatic_xacro_hooks.formatting.body import format_body, mark_eol_comments
from duatic_xacro_hooks.formatting.layout import XmlError, pretty_print, root_start
from duatic_xacro_hooks.formatting.tags import ATTRIBUTE_ORDER, check_attribute_orders
from duatic_xacro_hooks.common import (
    UnreadableFile,
    display_path,
    parse_nolint,
    read_utf8,
    suppresses,
)


def format_text(
    src: str,
    max_line_length: int = 100,
    indent_size: int = 2,
    indent_type: str = "space",
    label: str = "<stdin>",
) -> tuple[str, list[str]]:
    """Format the text of a xacro file. Everything above the root tag (the header) is kept as written.

    :param src: content of the file
    :param max_line_length: maximum line length
    :param indent_size: columns per indentation level
    :param indent_type: `space` or `tab`
    :param label: name of the input, used in error messages and warnings
    :returns: (formatted text, warnings as `label:line: warning: ...`)
    :raises XmlError: `src` is not well-formed XML
    """
    # eol comments are marked first so that re-indenting does not move them
    xml = pretty_print(mark_eol_comments(src), indent_size, label)
    header = src[: root_start(src)]
    body = format_body(xml[root_start(xml) :], max_line_length, indent_size, indent_type)

    # attribute-order warnings, unless the header has a nolint for them
    warnings = []
    header_nolints = (  # nolint comments above the root tag
        parse_nolint(m.group(1)) for m in re.finditer(r"<!--(.*?)-->", src[: root_start(src)], re.S)
    )
    if not any(
        is_nolint and suppresses(codes, "attribute-order") for is_nolint, codes in header_nolints
    ):
        offset = header.count("\n")
        warnings = [
            f"{label}:{lineno + offset}: warning: {msg}"
            for lineno, msg in check_attribute_orders(body)
        ]
    return header + body, warnings


def build_parser() -> argparse.ArgumentParser:
    """Command line parser of `format-xacro`.

    :returns: the parser
    """
    parser = argparse.ArgumentParser(
        prog="format-xacro",
        description=(
            "Format xacro files in place. Exit code: 0 ok, 1 --check would reformat, "
            "2 a file could not be formatted."
        ),
    )
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument(
        "--check", action="store_true", help="change nothing, exit 1 if a file would be reformatted"
    )
    parser.add_argument("--max-line-length", type=int, default=100)
    parser.add_argument("--indent-type", choices=["space", "tab"], default="space")
    parser.add_argument(
        "--indent-size",
        type=int,
        default=2,
        help="columns per indentation level (for tabs: the tab width used for line length)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point of `format-xacro`.

    :param argv: arguments (default: `sys.argv`)
    :returns: exit code: 0 ok, 1 `--check` would reformat a file, 2 a file could not be formatted
    """
    parser = build_parser()
    args = parser.parse_args(argv)

    status = 0  # 0 ok, 1 would reformat (--check), 2 error (wins)
    for path in args.files:
        try:
            raw, text = read_utf8(path)
        except UnreadableFile as e:
            print(f"{display_path(path)}: error: {e}", file=sys.stderr)
            status = 2
            continue

        src = text.replace("\r\n", "\n").replace("\r", "\n")

        try:
            text, warnings = format_text(
                src,
                args.max_line_length,
                args.indent_size,
                args.indent_type,
                label=display_path(path),
            )
        except XmlError as e:
            print(e, file=sys.stderr)
            status = 2
            continue

        for warning in warnings:
            print(warning, file=sys.stderr)

        data = text.encode("utf-8")
        if args.check:
            if data != raw:
                print(f"would reformat {display_path(path)}", file=sys.stderr)
                status = max(status, 1)
        elif data != raw:  # untouched files keep their modification time
            path.write_bytes(data)
    return status


__all__: list[str] = ["ATTRIBUTE_ORDER", "XmlError", "format_text", "main", "pretty_print"]


if __name__ == "__main__":
    sys.exit(main())
