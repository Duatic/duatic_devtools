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

"""The body below the root tag: blank lines, comments, macro calls, args and includes."""

from __future__ import annotations

import re
import textwrap

from duatic_xacro_hooks.formatting.layout import (
    EOL_MARKER,
    collapse_empty,
    indent_of,
    root_start,
    split_eol,
)
from duatic_xacro_hooks.formatting.tags import format_tag
from duatic_xacro_hooks.common import is_macro_call, parse_nolint


def mark_eol_comments(src: str) -> str:
    """Tag all comments behind other content on their line (re-indenting would put them on their own line).

    :param src: content of the file
    :returns: the text with the marked comments
    """
    start = root_start(src)

    def repl(m: re.Match[str]) -> str:
        """Mark a comment that follows other content on its line (not above the root tag).

        :param m: match of a comment or other token
        :returns: the replacement text
        """
        if m.group(1) or m.start() < start:
            return m.group(0)
        line_start = src.rfind("\n", 0, m.start()) + 1
        if src[line_start : m.start()].strip():
            return f"<!--{EOL_MARKER}{m.group(2)}-->"
        return m.group(0)

    return re.sub(r"(<!\[CDATA\[.*?\]\]>)|<!--(.*?)-->", repl, src, flags=re.S)


def place_eol_comments(lines: list[str]) -> None:
    """Comments that were at a line end: nolint goes back to the end of the line it followed, any
    other comment moves above that line (below it for a closing tag).

    :param lines: lines of the formatted text, changed in place
    """
    marker = "<!--" + EOL_MARKER
    for s, e in reversed(comment_ranges(lines)):
        first = lines[s].lstrip()
        if not first.startswith(marker):
            continue

        # drop the marker; comments that follow another comment (or the start) stay put
        lines[s] = lines[s][: len(lines[s]) - len(first)] + "<!--" + first[len(marker) :]
        prev = s - 1
        if prev < 0 or lines[prev].lstrip().startswith("<!--"):
            continue

        # a nolint goes back to the end of the line above
        is_nolint, codes = parse_nolint(lines[s].strip()[4:-3])
        if s == e and is_nolint:
            nolint = "<!-- nolint" + (f": {', '.join(sorted(codes))}" if codes else "") + " -->"
            lines[prev] = lines[prev].rstrip() + "  " + nolint
            del lines[s]
            continue

        # any other comment moves above the line it followed
        if split_eol(lines[prev])[0].lstrip().startswith("</"):
            continue  # stays below the closing tag as an own-line comment
        block = lines[s : e + 1]
        block[0] = lines[prev][: indent_of(lines[prev])] + block[0].lstrip()
        del lines[s : e + 1]
        lines[prev:prev] = block


def comment_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """(first line, last line) of every comment; single-line comments have first == last.

    Examples::

        >>> comment_ranges(["<a/>", "<!-- one -->", "<!--", "two", "-->"])
        [(1, 1), (2, 4)]

    :param lines: lines of the text
    :returns: the (first line, last line) pairs
    """
    ranges = []
    i = 0
    while i < len(lines):
        stripped = lines[i].lstrip()
        if stripped.startswith("<!--"):
            j = i
            if "-->" not in stripped[4:]:
                j += 1
                while j < len(lines) - 1 and "-->" not in lines[j]:
                    j += 1
            ranges.append((i, j))
            i = j + 1
        else:
            i += 1
    return ranges


def comment_block_start(lines: list[str], idx: int) -> int:
    """If the line(s) right above idx are comments, return the first line of that comment block.
    A block is a run of directly subsequent comments (single- or multi-line).

    Examples::

        >>> comment_block_start(["<a/>", "<!-- x -->", "<!-- y -->", "<b/>"], 3)
        1

    :param lines: lines of the text
    :param idx: index of the line below the comments
    :returns: the index of the first comment line, or `idx`
    """
    end_to_start = {e: s for s, e in comment_ranges(lines)}
    while idx - 1 in end_to_start:
        idx = end_to_start[idx - 1]
    return idx


def reformat_comments(lines: list[str], size: int, max_len: int) -> None:
    """Short single-line comments are kept. Every other comment (multi-line, or too long for
    max_len) becomes a block: `<!--` and `-->` on their own lines (aligned), the text at the
    same indentation, wrapped to max_len. Relative indentation of the text lines is
    kept, lines are never joined. Tabs are expanded, trailing whitespace is removed.

    :param lines: lines of the text, changed in place
    :param size: columns per indentation level
    :param max_len: maximum line length
    """
    for s, e in reversed(comment_ranges(lines)):
        first = lines[s].rstrip()
        col = indent_of(first)
        pad = " " * col

        # single-line comment: keep it if it fits, else wrap it
        if s == e:
            inner = first.strip()[4:-3].strip()
            if not inner or len(f"{pad}<!-- {inner} -->") <= max_len:
                lines[s] = f"{pad}<!-- {inner} -->" if inner else first
                continue
            texts = [(0, inner)]

        # multi-line comment: (relative indent, text) per line
        else:
            raw = [ln.expandtabs(size).rstrip() for ln in lines[s : e + 1]]
            head = raw[0].strip()[4:].strip()
            tail = raw[-1].strip()[:-3].strip() if raw[-1].strip().endswith("-->") else ""
            middle = raw[1:-1] + ([raw[-1].rstrip()[:-3].rstrip()] if tail else [])
            filled = [ln for ln in middle if ln.strip()]
            base = min((indent_of(ln) for ln in filled), default=0)
            texts = [(0, head)] if head else []
            texts += [
                (indent_of(ln) - base, ln.strip()) if ln.strip() else (0, "") for ln in middle
            ]

            # a trailing blank line before `-->` / leading blank after `<!--` carries no text
            while texts and not texts[0][1] and not head:
                texts.pop(0)
            while texts and not texts[-1][1]:
                texts.pop()

        # rebuild as a block with `<!--` and `-->` on their own lines
        out = [f"{pad}<!--"]
        for rel, text in texts:
            if not text:
                out.append("")
                continue
            text_pad = " " * (col + rel)
            width = max(max_len - len(text_pad), 1)
            for part in textwrap.wrap(
                text, width=width, break_long_words=False, break_on_hyphens=False
            ) or [""]:
                out.append(text_pad + part)
        out.append(f"{pad}-->")
        lines[s : e + 1] = out


def macro_call_name(line: str) -> str | None:
    """Name of the macro called on this line (opening or self-closing tag), if any.

    Examples::

        >>> macro_call_name('  <xacro:wheel a="1"/>')
        'wheel'
        >>> macro_call_name('<xacro:if value="1">') is None  # a directive, not a macro
        True

    :param line: one line of the body
    :returns: the macro name, or None
    """
    m = re.match(r"\s*<xacro:([\w.-]+)", line)
    return m.group(1) if m and is_macro_call(f"xacro:{m.group(1)}") else None


def ends_macro_call(line: str) -> str | None:
    """Macro name if this line completes a call: `<xacro:x .../>` or `</xacro:x>`.

    Examples::

        >>> ends_macro_call("</xacro:wheel>")
        'wheel'
        >>> ends_macro_call('<xacro:wheel a="1"/>')
        'wheel'
        >>> ends_macro_call('<xacro:wheel a="1">') is None  # still open
        True

    :param line: one line of the body
    :returns: the macro name, or None
    """
    line = split_eol(line)[0]
    m = re.match(r"\s*</xacro:([\w.-]+)>$", line)
    if m and is_macro_call(f"xacro:{m.group(1)}"):
        return m.group(1)
    return macro_call_name(line) if line.rstrip().endswith("/>") else None


def is_macro_def_start(line: str) -> bool:
    """Does the line open an `xacro:macro` definition?

    :param line: one line of the body
    :returns: True if it does
    """
    return re.match(r"\s*<xacro:macro[\s>]", line) is not None


def include_key(line: str) -> str:
    """Sort key of an include line: its filename.

    Examples::

        >>> include_key('  <xacro:include filename="a.xacro"/>')
        'a.xacro'

    :param line: line with an `xacro:include`
    :returns: the filename, empty if there is none
    """
    m = re.search(r'filename="([^"]*)"', line)
    return m.group(1) if m else ""


def scope_of(lines: list[str], idx: int, in_comment: set[int]) -> int:
    """Index of the line that opens the element containing line `idx` (0 for the root tag).

    Examples::

        >>> scope_of(["<robot>", "  <xacro:macro>", "    <a/>", "  </xacro:macro>"], 2, set())
        1

    :param lines: lines of the body, one element per line
    :param idx: index of the line
    :param in_comment: indexes of the comment lines (they carry no structure)
    :returns: the index of the opening tag line
    """
    col = indent_of(lines[idx])
    for j in range(idx - 1, -1, -1):
        if j not in in_comment and lines[j].strip() and indent_of(lines[j]) < col:
            return j
    return 0


def place_includes(lines: list[str], idxs: list[int], pos: int) -> None:
    """Move the include lines `idxs` (all in one scope) to `pos`, sorted by filename.
    A comment block at `pos` that mentions "include" stays above them.

    :param lines: lines of the body, changed in place
    :param idxs: indexes of the include lines
    :param pos: index of the first line of the scope body (behind its opening tag)
    """
    pad = lines[idxs[0]][: indent_of(lines[idxs[0]])]
    includes = [pad + lines[i].strip() for i in sorted(idxs, key=lambda i: include_key(lines[i]))]

    # the comments at `pos` are a heading of the includes if an include follows them directly (and
    # not just something that ended up behind them once the includes are lifted out)
    start_to_end = {s: e for s, e in comment_ranges(lines)}
    end = pos
    while end in start_to_end:
        end = start_to_end[end] + 1
    is_heading = (
        end > pos and end in idxs and re.search(r"include", "\n".join(lines[pos:end]), re.I)
    )

    for i in sorted(idxs, reverse=True):
        del lines[i]

    # a heading comment stays above the include group
    at = end if is_heading else pos
    lines[at:at] = includes


def move_args_and_includes(lines: list[str], indent: str) -> None:
    """Order behind the root tag: top-level `xacro:arg` (with the comment directly above), then the
    top-level `xacro:include` statements sorted by filename, without blank lines in between.
    Includes inside a macro or `xacro:if` go to the top of that element, sorted the same way; they
    never leave their scope. Includes whose filename depends on `${...}` stay where they are.
    Properties are not touched.

    :param lines: lines of the body, changed in place
    :param indent: indentation of the top level
    """
    arg_re = re.compile(rf"{indent}<xacro:arg[\s/>]")
    inc_re = re.compile(r"\s*<xacro:include[\s/>]")

    def scopes() -> dict[int, list[int]]:
        """Include lines to move, by the line that opens their scope.

        :returns: scope line index -> include line indexes
        """
        in_comment = {i for s, e in comment_ranges(lines) for i in range(s, e + 1)}
        groups: dict[int, list[int]] = {}
        for i, line in enumerate(lines):
            if i > 0 and i not in in_comment and inc_re.match(line) and "${" not in line:
                groups.setdefault(scope_of(lines, i, in_comment), []).append(i)
        return groups

    # top-level args (with their comment) go right behind the root tag
    in_comment = {i for s, e in comment_ranges(lines) for i in range(s, e + 1)}
    arg_ranges = [
        (comment_block_start(lines, i), i)
        for i, line in enumerate(lines)
        if i > 0 and i not in in_comment and arg_re.match(line)
    ]
    args = [ln for start, end in arg_ranges for ln in lines[start : end + 1]]
    for start, end in sorted(arg_ranges, reverse=True):
        del lines[start : end + 1]
    lines[1:1] = args

    # includes, scope by scope from top to bottom; the scopes are looked up again after every move
    done = -1
    while True:
        later = [p for p in scopes() if p > done]
        if not later:
            break
        done = min(later)
        pos = done + 1 + (len(args) if done == 0 else 0)
        place_includes(lines, scopes()[done], pos)


BLOCK_SCOPES = {"xacro:macro", "xacro:if", "xacro:unless"}  # the root's children are blocks too
PADDED_SCOPES = {"robot", "xacro:macro"}  # blank line behind the opening and above the closing tag
OPEN_TAG_NAME_RE = re.compile(r"<([\w:.-]+)")


def opens_scope(line: str) -> bool:
    """Does the line open an element that is closed on a later line?

    Examples::

        >>> opens_scope('<a x="1">'), opens_scope("<a/>"), opens_scope("<a>text</a>")
        (True, False, False)

    :param line: one line of the body
    :returns: True if it does
    """
    tag = split_eol(line)[0].strip()
    m = OPEN_TAG_NAME_RE.match(tag)
    if not m or tag.startswith(("<!--", "<?")) or tag.endswith("/>") or not tag.endswith(">"):
        return False
    return not tag.endswith(f"</{m.group(1)}>")


def block_spacing(lines: list[str], in_comment: set[int]) -> tuple[set[int], set[int], set[int]]:
    """Blank lines between the blocks of the scopes that hold blocks: the root, macro bodies and
    `xacro:if` / `unless` bodies. Every child element is a block and is separated from its
    neighbours by a blank line, except from a directly following block with the same tag name
    (macro definitions are always separated).
    Comments directly above a block belong to it: the blank line goes above them, and they
    separate it from an equal block above. The robot and macro bodies also have a blank line behind
    the opening and above the closing tag.

    :param lines: lines of the body, one element per line
    :param in_comment: indexes of the comment lines
    :returns: (lines that get a blank above, those where it is forced even right behind an opening
        tag, the child lines of these scopes)
    """
    above: set[int] = set()
    forced: set[int] = set()
    handled: set[int] = set()
    stack: list[tuple[int, str, list[int]]] = []  # (indent, tag, children) of the open elements

    def close(scope: tuple[int, str, list[int]], closing: int | None) -> None:
        """Add the blank lines of a scope whose closing tag is on line `closing`.

        :param scope: (indent, tag, child lines) of the scope
        :param closing: index of the line with its closing tag, if it has one
        """
        _, tag, kids = scope
        if tag not in BLOCK_SCOPES and tag != "robot":
            return
        handled.update(kids)
        names = [OPEN_TAG_NAME_RE.match(lines[k].lstrip()).group(1) for k in kids]  # type: ignore[union-attr]
        for n, kid in enumerate(kids):
            start = comment_block_start(lines, kid)
            if n == 0:
                if tag in PADDED_SCOPES:
                    above.add(start)
                    forced.add(start)
            elif names[n] != names[n - 1] or start != kid or names[n] == "xacro:macro":
                above.add(start)
        if tag in PADDED_SCOPES and kids and closing is not None:
            above.add(closing)
            forced.add(closing)

    for i, line in enumerate(lines):
        stripped = line.strip()
        if i in in_comment or not stripped:
            continue
        col = indent_of(line)
        while stack and col <= stack[-1][0]:
            close(stack.pop(), i if stripped.startswith("</") else None)
        if stripped.startswith("</") or not OPEN_TAG_NAME_RE.match(stripped):
            continue
        if stack:
            stack[-1][2].append(i)
        if i == 0 or opens_scope(line):
            tag = OPEN_TAG_NAME_RE.match(stripped).group(1)  # type: ignore[union-attr]
            stack.append((col, tag, []))
    while stack:
        close(stack.pop(), None)
    return above, forced, handled


def format_body(text: str, max_len: int, indent_size: int = 2, indent_type: str = "space") -> str:
    """Format everything below the root tag: blank lines, macro calls, comments, args, includes and tag wrapping.

    :param text: XML text with one element per line, starting at the root tag
    :param max_len: maximum line length
    :param indent_size: columns per indentation level
    :param indent_type: `space` or `tab`
    :returns: the formatted text
    """
    lines = collapse_empty(text).splitlines()
    if not lines:
        return text

    place_eol_comments(lines)
    # comments inside text content stay inline: just drop the marker
    lines = [ln.replace("<!--" + EOL_MARKER, "<!--") for ln in lines]

    unit = " " * indent_size  # lines are handled with space indentation, tabs come last
    reformat_comments(lines, indent_size, max_len)
    move_args_and_includes(lines, unit)

    # columns of every comment line, and where each comment block starts
    ranges = comment_ranges(lines)
    comment_col = {}  # comment line -> columns of structural indentation
    for s, e in ranges:
        col = indent_of(lines[s])
        for i in range(s, e + 1):
            comment_col[i] = col
    block_starts = set()
    prev_end = -2
    for s, e in ranges:
        if s != prev_end + 1:
            block_starts.add(s)
        prev_end = e

    # where blank lines go: between the blocks of the root, macro and `xacro:if` / `unless` bodies,
    # above comment blocks, and above the macro calls and definitions outside of those
    blank_before, force_blank, handled = block_spacing(lines, set(comment_col))
    blank_before |= block_starts
    for i, line in enumerate(lines):
        if i in comment_col or i in handled:
            continue
        if macro_call_name(line) is not None or is_macro_def_start(line):
            # keep a leading comment block attached to the tag it documents
            start = comment_block_start(lines, i)
            if start == i and i > 0 and macro_call_name(line):
                # subsequent calls of the same macro stay together
                prev = lines[i - 1]
                same_indent = indent_of(prev) == indent_of(line)
                if same_indent and ends_macro_call(prev) == macro_call_name(line):
                    continue
            blank_before.add(start)
            if is_macro_def_start(line):
                force_blank.add(start)

    # emit the lines with their blank lines, wrapping tags
    out: list[tuple[str, int]] = []  # (text, columns of structural indentation)
    after_container = False  # last emitted line opens a parent tag (maybe wrapped)

    def add_blank(force: bool = False) -> None:
        """Add a blank line unless the last one is blank or opens a parent tag.

        :param force: also add it right behind an opening parent tag
        """
        if out and out[-1][0].strip() and (force or not after_container):
            out.append(("", 0))

    for i, line in enumerate(lines):
        # a blank line above this line, and none are kept from the source
        if i in blank_before:
            add_blank(force=i in force_blank)
        if not line.strip():
            if out and out[-1][0].strip():
                out.append(("", 0))
            continue
        if i in comment_col:
            out.append((line, comment_col[i]))
            after_container = False
            continue

        cols = indent_of(line)
        out.extend((ln, cols) for ln in format_tag(line, max_len))
        tag = split_eol(line)[0].strip()
        after_container = (  # an opening tag that has children, e.g. `<robot ...>`
            tag.startswith("<")
            and not tag.startswith(("</", "<!--", "<?"))
            and tag.endswith(">")
            and not tag.endswith("/>")
        )

    while out and not out[-1][0].strip():
        out.pop()

    # tabs replace the structural indentation only
    result = []
    for text, cols in out:
        if indent_type == "tab":
            lead = min(cols, len(text) - len(text.lstrip(" "))) // indent_size * indent_size
            text = "\t" * (lead // indent_size) + text[lead:]
        result.append(text)
    return "\n".join(result) + "\n"
