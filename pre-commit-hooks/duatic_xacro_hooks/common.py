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

"""
Code shared by the formatter and the checker: `nolint` directives, xacro tag names, reading files.

`nolint` directives:

    <!-- nolint -->                   above <robot>: whole file, every check
    <!-- nolint: code-a, code-b -->   above <robot>: whole file, only these checks
    <link name="${x}"/>  <!-- nolint -->           at a line end: this line (tag), every check
    <link name="${x}"/>  <!-- nolint: code-a -->   at a line end: this line (tag), only code-a

A nolint comment anywhere else has no effect. Other comments at a line end are not allowed.
"""

import re
from pathlib import Path

# xacro tags that are directives, i.e. not user-defined macro calls
XACRO_BUILTINS: set[str] = {
    "macro", "property", "arg", "include", "if", "unless", "insert_block", "element", "attribute", "call",
}  # fmt: skip


def is_macro_call(tag: str) -> bool:
    """Is the tag a call of a user macro (an `xacro:` tag that is not a directive)?

    Examples::

        >>> is_macro_call("xacro:wheel"), is_macro_call("xacro:if"), is_macro_call("link")
        (True, False, False)

    :param tag: tag name as `xacro:name` or the plain name
    :returns: True for a macro call
    """
    return tag.startswith("xacro:") and tag[len("xacro:") :] not in XACRO_BUILTINS


# One param with a default, as xacro reads it (`re_macro_arg` of xacro 2.x): name, `:=` or `=`, an
# optional `^` / `^|` (take the outer-scope value) and the default. The default ends at whitespace
# outside quotes, `${...}` and `$(...)`; like in xacro, `${...}` / `$(...)` glued to other text
# (`$(find p)/x`) ends at its first space. `&quot;` is a double quote in the raw text of the formatter.
_DEFAULT = r"\$\{.*?\}|\$\(.*?\)|(?:'.*?'|\".*?\"|&quot;.*?&quot;|(?:(?!&quot;)[^\s'\"])+)+|"
PARAM_DEFAULT_RE = re.compile(
    rf"\s*(?P<name>[^\s:=]+?)\s*(?P<op>:?=)\s*(?P<default>(?:\^\|?)?(?:{_DEFAULT}))(?:\s+|$)",
    re.DOTALL,
)

NOLINT_RE = re.compile(
    r"^\s*nolint(?:\s*:\s*(?P<codes>[\w-]+(?:\s*,\s*[\w-]+)*))?\s*$", re.IGNORECASE
)


def parse_nolint(comment_text: str) -> tuple[bool, frozenset[str]]:
    """(is a nolint comment, codes); no codes means all checks.

    Examples::

        >>> is_nolint, codes = parse_nolint("nolint: a, b")
        >>> is_nolint, sorted(codes)
        (True, ['a', 'b'])
        >>> parse_nolint("just a comment")[0]
        False

    :param comment_text: text between `<!--` and `-->`
    :returns: (is a nolint comment, codes); no codes means all checks
    """
    m = NOLINT_RE.match(comment_text)
    if not m:
        return False, frozenset()
    codes = m.group("codes")
    return True, frozenset(c.strip() for c in codes.split(",")) if codes else frozenset()


def suppresses(codes: frozenset[str], code: str) -> bool:
    """Does a nolint with these codes silence a check?

    Examples::

        >>> suppresses(frozenset(), "x")
        True
        >>> suppresses(frozenset({"a"}), "b")
        False

    :param codes: codes of the nolint (none: all)
    :param code: code of the check
    :returns: True if it does
    """
    return not codes or code in codes


def _parse_params(params: str | None) -> list[tuple[str, str, str]]:
    """Split the `params` attribute of a macro the way xacro does (`parse_macro_arg`).

    :param params: value of the attribute (may be None)
    :returns: (name, operator, default) per param; operator and default are empty without a default
    """
    out: list[tuple[str, str, str]] = []
    rest = params or ""
    while rest.strip():
        m = PARAM_DEFAULT_RE.match(rest)
        if m:
            out.append((m["name"], m["op"], m["default"]))
            rest = rest[m.end() :]
        else:
            # no default: the name ends at the next whitespace
            name, *tail = rest.split(None, 1)
            out.append((name, "", ""))
            rest = tail[0] if tail else ""
    return out


def split_params(params: str | None) -> list[str]:
    """Split the `params` attribute of a macro into one text per param, e.g. `a:=1`.

    Params are separated by whitespace outside quotes, `${...}` and `$(...)`, exactly where xacro
    separates them. xacro also accepts spaces around the operator of a default (`b :=2`, `c:= 3`),
    which this joins to `b:=2` and `c:=3`.

    Examples::

        >>> split_params("a b:=1 *c")
        ['a', 'b:=1', '*c']
        >>> split_params("a :=1  b := 'x y'  c:= 3")
        ['a:=1', "b:='x y'", 'c:=3']
        >>> split_params("a:=${x == 1} b:=${'p q' if x else 2} c")
        ['a:=${x == 1}', "b:=${'p q' if x else 2}", 'c']
        >>> split_params('a:=$(arg x) b:="p q" c:=&quot;r s&quot; d:=^|${1 + 2}')
        ['a:=$(arg x)', 'b:="p q"', 'c:=&quot;r s&quot;', 'd:=^|${1 + 2}']
        >>> split_params("a:=$(find p)/x b")  # xacro splits this as well
        ['a:=$(find', 'p)/x', 'b']

    :param params: value of the attribute (may be None)
    :returns: the params as written, without spaces around `:=`
    """
    return [name + op + default for name, op, default in _parse_params(params)]


def canonical_params(params: str | None) -> list[str]:
    """Like `split_params`, with every default written `:=`, the usual spelling.

    xacro also accepts a plain `=` (`a=1`), but the ROS wiki and all packages use `:=`.

    Examples::

        >>> canonical_params("a=1 b:=2 c")
        ['a:=1', 'b:=2', 'c']
        >>> canonical_params("a=${x==1}")
        ['a:=${x==1}']
        >>> canonical_params("a=${x == 1} b")
        ['a:=${x == 1}', 'b']

    :param params: value of the attribute (may be None)
    :returns: the params, each with `:=` for its default
    """
    return [name + (":=" if op else "") + default for name, op, default in _parse_params(params)]


def display_path(path: Path) -> str:
    """The path of a file as shown in messages: relative to the working directory if it is below it.

    :param path: the file
    :returns: the relative path, or the path as given
    """
    resolved = path.resolve()
    cwd = Path.cwd()
    return str(resolved.relative_to(cwd)) if resolved.is_relative_to(cwd) else str(path)


class UnreadableFile(Exception):
    """A file that cannot be read as UTF-8; the message is the reason."""


def read_utf8(path: Path) -> tuple[bytes, str]:
    """The content of a file as bytes and as text.

    :param path: the file to read
    :returns: the raw bytes and the decoded text
    :raises UnreadableFile: if the file cannot be read or is not UTF-8 (xacro reads only UTF-8)

    :param path: the file to read
    :returns: the raw bytes and the decoded text
    :raises UnreadableFile: the file cannot be read or is not UTF-8 (xacro reads only UTF-8)
    """
    try:
        raw = path.read_bytes()
        return raw, raw.decode("utf-8")
    except UnicodeDecodeError:
        raise UnreadableFile("not a valid UTF-8 file") from None
    except OSError as e:
        raise UnreadableFile(e.strerror) from None
