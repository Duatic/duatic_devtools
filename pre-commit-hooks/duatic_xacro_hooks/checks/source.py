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

"""The file itself: strict parsing, `nolint` comments, XML declaration, top-level order, origins."""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from lxml import etree

from duatic_xacro_hooks.checks.model import Issue, children, elements, enclosing_macro, tag_name
from duatic_xacro_hooks.common import parse_nolint

if TYPE_CHECKING:
    from duatic_xacro_hooks.checks.model import Element


FIND_START_RE = re.compile(r"\$\(find\s+[\w.-]+\)")  # `$(find pkg)` at the start of a path
UNBOUND_PREFIX_RE = re.compile(
    r"Namespace prefix (?P<prefix>\S+)(?: for (?P<attr>\S+))? on (?P<tag>\S+) is not defined"
)


def parse_strict(text: str) -> tuple[Element | None, list[Issue]]:
    """(root, []) or (None, hard errors). Not well-formed XML and unbound prefixes are errors.

    :param text: content of the file
    :returns: (root element, []) or (None, hard errors)
    """
    parser = etree.XMLParser(remove_comments=False, encoding="utf-8")
    try:
        return etree.fromstring(text.encode("utf-8"), parser), []
    except etree.XMLSyntaxError as e:
        errors, seen = [], set()

        # one issue per log entry, unbound prefixes reported with a hint, duplicates dropped
        for entry in parser.error_log:  # this parse only (the exception's log is shared)
            m = UNBOUND_PREFIX_RE.search(entry.message)
            if m:
                where = (
                    f"attribute '{m['prefix']}:{m['attr']}' of <{m['tag']}>"
                    if m["attr"]
                    else f"<{m['prefix']}:{m['tag']}>"
                )
                issue = Issue(
                    entry.line,
                    "unbound-prefix",
                    f"namespace prefix '{m['prefix']}' used in {where} is not declared, "
                    f"add xmlns:{m['prefix']}=\"...\" to the root tag",
                )
            else:
                issue = Issue(entry.line, "parse-error", entry.message)
            if issue not in seen:
                seen.add(issue)
                errors.append(issue)
        return None, errors or [Issue(1, "parse-error", str(e))]


def collect_directives(
    root: Element, lines: list[str]
) -> tuple[list[frozenset[str]], dict[int, list[frozenset[str]]], list[Issue]]:
    """nolint directives and misplaced comments.
    Returns (file-level code sets, {line: code sets}, issues about the comments themselves).

    :param root: root element of the file
    :param lines: the lines of the file
    :returns: (file-level code sets, {line: code sets}, issues about the comments themselves)
    """
    file_level: list[frozenset[str]] = []
    per_line: dict[int, list[frozenset[str]]] = {}
    issues: list[Issue] = []

    # file-level nolint: comments above the root element
    for comment in root.itersiblings(preceding=True):
        if comment.tag is etree.Comment:
            is_nolint, codes = parse_nolint(comment.text or "")
            if is_nolint:
                file_level.append(codes)

    # comments inside the root: find the line they start in and whether they trail a line
    for comment in root.iter(etree.Comment):
        text = comment.text or ""
        start = comment.sourceline - text.count("\n")  # lxml reports the line a comment ends in
        line = lines[start - 1] if 0 < start <= len(lines) else ""
        idx = line.find("<!--" + text.split("\n")[0])
        idx = line.find("<!--") if idx < 0 else idx
        at_eol = line[:idx].strip() != ""
        is_nolint, codes = parse_nolint(text)

        # an end-of-line nolint covers its line; nolint elsewhere does nothing (the formatter moves
        # other trailing comments)
        if at_eol and is_nolint:
            affected = {start}
            prev = comment.getprevious()
            if prev is not None and tag_name(prev):  # a tag spanning lines: its first line too
                affected.add(prev.sourceline)
            for ln in affected:
                per_line.setdefault(ln, []).append(codes)
        elif is_nolint and not at_eol:
            issues.append(
                Issue(
                    start,
                    "nolint-placement",
                    "nolint only works above <robot> or at the end of a line",
                )
            )
    return file_level, per_line, issues


def check_include_find(root: Element) -> list[Issue]:
    """Every `xacro:include` must name its file as `$(find <pkg>)/...` (`include-without-find`).

    A relative path depends on the including file, an absolute one on the machine.

    :param root: root element of the file
    :returns: the issues found
    """
    return [
        Issue(
            el.sourceline,
            "include-without-find",
            f"include '{el.get('filename')}' does not start with $(find <pkg>)",
        )
        for el in elements(root)
        if tag_name(el) == "xacro:include" and not FIND_START_RE.match(el.get("filename") or "")
    ]


LAZY_TOP_LEVEL = {"xacro:macro", "xacro:property", "xacro:arg", "xacro:include"}


def check_include_placement(root: Element) -> list[Issue]:
    """Where an include may be (`include-placement`): an include with a static filename at the top of
    the file, after xacro:args (only args and other includes above it), one with `${...}` at the top of its macro
    (only other includes above it). Includes with `${...}` outside of a macro are not checked.

    :param root: root element of the file
    :returns: the issues found
    """
    issues = []
    for el in elements(root):
        if tag_name(el) != "xacro:include":
            continue
        variable = "${" in (el.get("filename") or "")
        parent = el.getparent()
        if variable:
            scope = enclosing_macro(el)
            if scope is None:
                continue
            ok_before, where = {"xacro:include"}, "the top of its macro"
            ok = parent is scope
        else:
            ok_before, where = {
                "xacro:include",
                "xacro:arg",
            }, "the top of the file (after xacro:args)"
            ok = parent is root
        before = {tag_name(s) for s in el.itersiblings(preceding=True) if tag_name(s)}
        if not ok or not before <= ok_before:
            kind = "variable" if variable else "static"
            issues.append(
                Issue(el.sourceline, "include-placement", f"{kind} include must be at {where}")
            )
    return issues


def check_library(root: Element) -> list[Issue]:
    """A file whose `<robot>` has no `name` is a library (a file with a name is a top-level one) and
    may only define macros, properties, args and includes at its top level (`library-not-lazy`).

    Anything else (`xacro:if`, output elements, macro calls) is evaluated while the file is
    included, in the scope of the including file, so the result depends on what that file has
    defined by then. Macros and property values are evaluated on use, so they do not.

    :param root: root element of the file
    :returns: the issues found
    """
    if tag_name(root) != "robot" or root.get("name") is not None:
        return []
    return [
        Issue(
            el.sourceline,
            "library-not-lazy",
            f"<{tag_name(el)}> is evaluated when the file is included; a file without a robot "
            "name may only define macros, properties, args and includes",
        )
        for el in children(root)
        if tag_name(el) not in LAZY_TOP_LEVEL
    ]


def check_declaration(text: str) -> list[Issue]:
    """The XML declaration must be there (a malformed or misplaced one is a parse error) and, if it
    declares an encoding, that must be UTF-8: xacro ignores the declaration and always reads UTF-8.

    :param text: content of the file
    :returns: the issues found
    """
    declaration = re.match(r"\ufeff?<\?xml\s.*?\?>", text, re.S)
    if not declaration:
        return [
            Issue(
                1,
                "xml-declaration",
                'missing XML declaration, start the file with <?xml version="1.0"?>',
            )
        ]
    encoding = re.search(r"""\sencoding\s*=\s*(["'])(.*?)\1""", declaration.group(0))
    if encoding and encoding.group(2).lower() != "utf-8":
        return [
            Issue(
                1,
                "xml-encoding",
                f"declared encoding '{encoding.group(2)}' is not UTF-8, xacro only reads UTF-8",
            )
        ]
    return []


def check_origins(root: Element) -> list[Issue]:
    """`<origin>` with both `rpy` and `quat_xyzw` (`origin-rotation`).

    :param root: root element of the file
    :returns: the issues found
    """
    return [
        Issue(el.sourceline, "origin-rotation", "<origin> has both rpy and quat_xyzw")
        for el in elements(root)
        if tag_name(el) == "origin"
        and el.get("rpy") is not None
        and el.get("quat_xyzw") is not None
    ]
