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

"""Data types and element helpers shared by the checks."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

from duatic_xacro_hooks.common import is_macro_call, split_params

if TYPE_CHECKING:
    from collections.abc import Iterator
    from typing import TypeAlias

    from lxml import etree

    Element: TypeAlias = etree._Element  # lxml has no type stubs
    Registry: TypeAlias = "dict[str, list[MacroDef]]"  # macro name -> its definitions


@dataclass(frozen=True)
class Issue:
    """A finding of a check.

    :ivar line: the line it is reported at
    :ivar code: the check code, a key of `CODES`
    :ivar message: what is wrong
    """

    line: int
    code: str
    message: str


@dataclass(frozen=True)
class Param:
    """One param of a macro.

    :ivar raw: the param as written, e.g. `**origin` or `a:=1`
    :ivar name: the name without asterisks and default
    :ivar kind: `value`, `block` (`*name`) or `multi` (`**name`)
    """

    raw: str
    name: str
    kind: str  # "value", "block" (*x) or "multi" (**x)

    @property
    def required(self) -> bool:
        """A value param without a default: a call has to set it.

        :returns: True for a value param (`a`) without a default (`a:=1`)
        """
        return self.kind == "value" and "=" not in self.raw

    @property
    def forwards(self) -> bool:
        """A value param that takes the outer-scope value of the same name (`a:=^`, `a:=^|x`).

        :returns: True if the default starts with `^`
        """
        return self.kind == "value" and "=^" in self.raw


@dataclass(frozen=True)
class MacroDef:
    """A macro definition.

    :ivar path: the file that defines it, as shown in messages
    :ivar line: the line of the definition
    :ivar params: its params, in order
    """

    path: str
    line: int
    params: tuple[Param, ...]


def tag_name(el: Element) -> str | None:
    """`xacro:macro` for tags with the prefix `xacro:` (xacro itself goes by the prefix, not by the
    namespace URI), the plain local name otherwise, None for comments and processing instructions.

    :param el: an element, comment or processing instruction
    :returns: the tag name, or None if it is not an element
    """
    tag = el.tag
    if not isinstance(tag, str):
        return None
    local = tag.split("}", 1)[1] if tag.startswith("{") else tag
    return f"xacro:{local}" if el.prefix == "xacro" else local


def elements(root: Element) -> list[Element]:
    """All elements below `root` (and `root`), without comments and processing instructions.

    :param root: the element
    :returns: the elements, in document order
    """
    return [el for el in root.iter() if tag_name(el)]


def children(el: Element) -> list[Element]:
    """The child elements of an element, without comments and processing instructions.

    :param el: the element
    :returns: the children
    """
    return [c for c in el if tag_name(c)]


def enclosing_macro(el: Element) -> Element | None:
    """The `xacro:macro` element that contains an element.

    :param el: the element
    :returns: the macro, or None if it is not inside one
    """
    for anc in el.iterancestors():
        if tag_name(anc) == "xacro:macro":
            return anc
    return None


def has_unseen_code(macro: Element, registry: Registry) -> bool:
    """Does a macro body run code that we cannot see: an unknown macro, a run-time call or an include?

    xacro scopes dynamically: such code may read this macro's params and blocks by name, so a check
    that finds none of them used cannot be sure.

    :param macro: the `xacro:macro` element
    :param registry: macro definitions of all known files
    :returns: True if the body calls an unknown macro, a macro chosen at run time, or includes a file
    """
    for call in elements(macro):
        tag = tag_name(call) or ""
        name = tag[len("xacro:") :]

        # `<xacro:call macro="${name}">` and `<xacro:include>` bring in code that we do not read
        if tag in ("xacro:call", "xacro:include"):
            return True

        if is_macro_call(tag) and name not in registry:
            return True
    return False


def parse_params(params: str | None) -> list[Param]:
    """Split the `params` attribute of a macro into its params.

    Examples::

        >>> [(p.name, p.kind, p.required) for p in parse_params("a b:=1 *c **d")]
        [('a', 'value', True), ('b', 'value', False), ('c', 'block', False), ('d', 'multi', False)]

    :param params: value of the attribute (may be None)
    :returns: the params, in order
    """
    result = []
    for raw in split_params(params):
        # one asterisk: block param, two: multi param
        stars = len(raw) - len(raw.lstrip("*"))
        name = re.split(r":?=", raw.lstrip("*"), maxsplit=1)[0]
        kind = "value" if stars == 0 else ("block" if stars == 1 else "multi")
        result.append(Param(raw, name, kind))
    return result


def texts(el: Element) -> Iterator[str]:
    """Everything of an element that xacro evaluates: attribute values and text.

    :param el: the element
    :returns: the attribute values and the non-blank text and tail
    """
    yield from el.attrib.values()

    for t in (el.text, el.tail):
        if t and t.strip():
            yield t
