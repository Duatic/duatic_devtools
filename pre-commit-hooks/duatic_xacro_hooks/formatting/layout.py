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

"""Strict XML parsing and layout (one element per line), and the regular expressions and line
helpers that all formatting steps share."""

from __future__ import annotations

import re
from io import BytesIO
from typing import TYPE_CHECKING

from lxml import etree

if TYPE_CHECKING:
    from collections.abc import Iterable


NAME = r"[\w:.-]+"


ATTR_RE = re.compile(rf'({NAME})="([^"]*)"')


# <tag a="1" b="2"> / <tag a="1" b="2"/> on a single line
OPEN_TAG_RE = re.compile(rf'^(\s*)<({NAME})((?:\s+{NAME}="[^"]*")+)\s*(/?>)$')


# comments, PIs, CDATA (skipped over) or the start of an element
TOKEN_RE = re.compile(rf"<!--.*?-->|<\?.*?\?>|<!\[CDATA\[.*?\]\]>|<({NAME})", re.S)


# element without content, e.g. <a x="1"></a> or <a>\n</a>
EMPTY_ELEM_RE = re.compile(
    rf'(<!--.*?-->|<!\[CDATA\[.*?\]\]>)|<({NAME})((?:\s+{NAME}="[^"]*")*)\s*>\s*</\2>', re.S
)


def indent_of(line: str) -> int:
    """Number of leading whitespace characters.

    :param line: one line
    :returns: the indentation
    """
    return len(line) - len(line.lstrip())


def join_attrs(pairs: Iterable[tuple[str, str]]) -> str:
    """Attributes as a single space separated ``name="value"`` string.

    Examples::

        >>> join_attrs([("a", "1"), ("b", "2")])
        'a="1" b="2"'

    :param pairs: (name, value) pairs
    :returns: the attributes as text
    """
    return " ".join(f'{n}="{v}"' for n, v in pairs)


def root_start(text: str) -> int:
    """Index at which the root tag starts (after the XML declaration, comments, ...).

    Examples::

        >>> root_start('<?xml version="1.0"?>\\n<!-- c -->\\n<robot/>')
        33

    :param text: content of the file
    :returns: the index, 0 if there is no element
    """
    for m in TOKEN_RE.finditer(text):
        if m.group(1):
            return m.start()
    return 0


def collapse_empty(text: str) -> str:
    """Close tags without a body on the same line.

    Examples::

        >>> collapse_empty('<a x="1"></a>')
        '<a x="1"/>'

    :param text: XML text
    :returns: the text with self-closing tags
    """

    def repl(m: re.Match[str]) -> str:
        """Replace an empty element by a self-closing tag; comments and CDATA stay.

        :param m: match of an empty element, a comment or CDATA
        :returns: the replacement text
        """
        if m.group(1):
            return m.group(1)
        return f"<{m.group(2)}{m.group(3)}/>"

    return EMPTY_ELEM_RE.sub(repl, text)


# `<tag .../>  <!-- nolint -->`: the only kind of comment allowed at the end of a line
EOL_NOLINT_RE = re.compile(r"^(?P<code>.*\S)\s+(?P<eol><!--\s*nolint\b.*?-->)\s*$")


EOL_MARKER = (
    "@EOL@"  # tags comments that were at a line end in the source while the XML is re-indented
)


def split_eol(line: str) -> tuple[str, str]:
    """(line without its trailing nolint comment, that comment or "").

    Examples::

        >>> split_eol('<a/>  <!-- nolint: x -->')
        ('<a/>', '<!-- nolint: x -->')
        >>> split_eol('<a/>')
        ('<a/>', '')

    :param line: one line
    :returns: (the code, the nolint comment or an empty string)
    """
    m = EOL_NOLINT_RE.match(line)
    return (m["code"], m["eol"]) if m else (line, "")


class XmlError(Exception):
    """The input is not well-formed XML (or not UTF-8)."""


XML_SPACE = "{http://www.w3.org/XML/1998/namespace}space"


def indent_elements(el: etree._Element, unit: str, level: int = 0) -> None:
    """Indent like libxml2's formatter (xmllint --format): children go on their own lines, except
    in elements with text content (mixed content) or xml:space="preserve", whose whole subtree
    is left untouched. Works for any indent unit, unlike etree.indent / pretty_print.

    :param el: element to indent, changed in place
    :param unit: text of one indentation level
    :param level: nesting level of `el`
    """
    children = list(el)  # elements, comments and processing instructions
    if not children:
        return

    # mixed content and xml:space="preserve" are left alone
    mixed = el.text is not None or any(
        c.tail is not None or c.tag is etree.Entity for c in children
    )
    if mixed or el.get(XML_SPACE) == "preserve":
        return

    # indent bottom-up; the last child's tail dedents to the closing tag
    for i, child in enumerate(children):
        indent_elements(child, unit, level + 1)
        child.tail = "\n" + unit * (level + 1 if i < len(children) - 1 else level)
    el.text = "\n" + unit * (level + 1)


def parse_error_lines(error: etree.XMLSyntaxError, parser: etree.XMLParser, label: str) -> str:
    """The parser errors of one parse as `label:line:column: parser error: message` lines.

    :param error: the exception that was raised
    :param parser: the parser that was used (its error log is for this parse only)
    :param label: name of the input
    :returns: the error lines
    """
    lines = []
    for entry in parser.error_log:  # this parse only (the exception's log is shared)
        line = f"{label}:{entry.line}:{entry.column}: parser error: {entry.message}".replace(
            EOL_MARKER, ""
        )
        if line not in lines:
            lines.append(line)
    return "\n".join(lines) or f"{label}: parser error: {error}"


def pretty_print(text: str, indent_size: int, label: str = "<stdin>") -> str:
    """The XML text with one element per line and the given indentation (what `xmllint --format`
    does). Strict: not well-formed XML, including unbound namespace prefixes, raises XmlError.
    CDATA, entity references and non-ASCII characters are kept as they are, and so is the XML
    declaration (verbatim; there is none in the output if there was none in the input).

    :param text: content of the file
    :param indent_size: columns per indentation level
    :param label: name of the input, used in error messages
    :returns: the formatted XML text
    :raises XmlError: `text` is not well-formed XML (including unbound prefixes)
    """
    parser = etree.XMLParser(
        remove_blank_text=True, strip_cdata=False, resolve_entities=False, encoding="utf-8"
    )
    try:
        tree = etree.parse(BytesIO(text.encode("utf-8")), parser)
    except etree.XMLSyntaxError as e:
        raise XmlError(parse_error_lines(e, parser, label)) from None

    root = tree.getroot()
    indent_elements(root, " " * indent_size)

    # top-level comments, processing instructions and DOCTYPE around the root, each on its own
    # line and in their original order
    root_text = etree.tostring(root, encoding="unicode", with_tail=False)
    full = etree.tostring(tree, encoding="unicode")
    start = full.find(root_text)
    top = re.compile(r"<!--.*?-->|<\?.*?\?>|<!DOCTYPE\s[^\[>]*(?:\[.*?\]\s*)?>", re.S)
    before, after = top.findall(full[:start]), top.findall(full[start + len(root_text) :])
    declaration = re.match(r"<\?xml\s.*?\?>", text.lstrip("\ufeff"), re.S)
    return (
        "\n".join([*([declaration.group(0)] if declaration else []), *before, root_text, *after])
        + "\n"
    )
