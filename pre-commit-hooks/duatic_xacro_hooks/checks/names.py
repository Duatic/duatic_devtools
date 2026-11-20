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

"""Which names `${...}` expressions use, and the checks of args and unused macro params."""

from __future__ import annotations

import ast
import re
from typing import TYPE_CHECKING

from duatic_xacro_hooks.checks.model import (
    Issue,
    has_unseen_code,
    elements,
    enclosing_macro,
    parse_params,
    tag_name,
    texts,
)
from duatic_xacro_hooks.common import is_macro_call

if TYPE_CHECKING:
    from duatic_xacro_hooks.checks.model import Element, Registry


ARG_SUBST_RE = re.compile(r"\$\(arg\s+([^)\s]+)\s*\)")


def extract_exprs(text: str) -> list[str]:
    """Contents of all `${...}` in text (brace matching, strings are skipped).

    Examples::

        >>> extract_exprs("a${x}b${y + 1}")
        ['x', 'y + 1']
        >>> extract_exprs("$${x}")
        []
        >>> extract_exprs("${'}' + x}")
        ["'}' + x"]

    :param text: attribute value or text of an element
    :returns: the text of every expression
    """
    out: list[str] = []
    i = 0
    while True:
        i = text.find("${", i)
        if i < 0:
            return out
        if i > 0 and text[i - 1] == "$":  # `$${` is an escape
            i += 2
            continue

        # scan to the matching `}`, ignoring braces inside quoted strings
        j, depth, quote = i + 2, 1, None
        while j < len(text) and depth:
            c = text[j]
            if quote:
                if c == "\\":
                    j += 1
                elif c == quote:
                    quote = None
            elif c in "'\"":
                quote = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            j += 1
        if depth == 0:
            out.append(text[i + 2 : j - 1])
        i = j


def _free(node: ast.AST, bound: frozenset[str], out: set[str]) -> None:
    """Collect the names that an expression reads and does not bind itself.

    :param node: AST node of the expression
    :param bound: names bound by the enclosing comprehensions and lambdas
    :param out: set that receives the free names
    """
    if isinstance(node, ast.Name):
        if isinstance(node.ctx, ast.Load) and node.id not in bound:
            out.add(node.id)
    elif isinstance(node, ast.Lambda):
        a = node.args
        names = {x.arg for x in a.posonlyargs + a.args + a.kwonlyargs}
        names |= {x.arg for x in (a.vararg, a.kwarg) if x}
        for d in a.defaults + [d for d in a.kw_defaults if d]:
            _free(d, bound, out)
        _free(node.body, bound | names, out)
    elif isinstance(node, (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)):
        stored = {
            n.id for n in ast.walk(node) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store)
        }
        for child in ast.iter_child_nodes(node):
            _free(child, bound | stored, out)
    else:
        for child in ast.iter_child_nodes(node):
            _free(child, bound, out)


def free_names(expr: str) -> set[str]:
    """Names an expression reads that it does not bind itself (comprehension vars, lambdas).

    Examples::

        >>> sorted(free_names("[i * p for i in range(3)]"))
        ['p', 'range']
        >>> sorted(free_names("a.b(c)"))
        ['a', 'c']

    :param expr: a Python expression
    :returns: the free names
    """
    try:
        tree = ast.parse(expr.strip(), mode="eval")
    except SyntaxError:
        return set()
    out: set[str] = set()
    _free(tree, frozenset(), out)
    return out


def check_args(root: Element) -> list[Issue]:
    """Where `xacro:arg` and `$(arg ...)` may be used (`arg-placement`).

    :param root: root element of the file
    :returns: the issues found
    """
    issues = []
    for el in elements(root):
        macro = enclosing_macro(el)

        # declarations only at top level
        if tag_name(el) == "xacro:arg" and el.getparent() is not root:
            where = f"macro '{macro.get('name')}'" if macro is not None else "a nested tag"
            issues.append(
                Issue(
                    el.sourceline,
                    "arg-placement",
                    f"xacro:arg inside {where}, declare it at top level",
                )
            )

        # `$(arg ...)` substitutions are resolved at load time, so not inside macros
        if macro is not None and el is not macro:
            for t in texts(el):
                for m in ARG_SUBST_RE.finditer(t):
                    issues.append(
                        Issue(
                            el.sourceline,
                            "arg-placement",
                            f"$(arg {m.group(1)}) inside macro '{macro.get('name')}', pass it as a macro param",
                        )
                    )
    return issues


def check_unused_params(root: Element, registry: Registry) -> list[Issue]:
    """Value params of a macro that its body never uses (`unused-param`).

    A param also counts as used if a macro called in the body forwards a param of the same name
    with `^` (`a:=^`) and the call does not set it. A macro that calls an unknown macro or includes a file is skipped.

    :param root: root element of the file
    :param registry: macro definitions of all known files
    :returns: the issues found
    """
    issues = []
    for macro in (el for el in elements(root) if tag_name(el) == "xacro:macro"):
        # a called macro we cannot see may read the params (xacro scopes dynamically)
        if has_unseen_code(macro, registry):
            continue

        # names read by any `${...}` below the macro element (its own params attribute excluded)
        used = set()
        for el in elements(macro):
            if el is not macro:
                used |= {n for t in texts(el) for e in extract_exprs(t) for n in free_names(e)}

        # names that a called macro forwards implicitly: its `a:=^` param, if the call leaves it out
        for call in elements(macro):
            tag = tag_name(call) or ""
            if not is_macro_call(tag):
                continue
            for definition in registry.get(tag[len("xacro:") :], []):
                used |= {
                    p.name for p in definition.params if p.forwards and p.name not in call.attrib
                }

        for p in parse_params(macro.get("params")):
            if p.kind == "value" and p.name not in used:
                issues.append(
                    Issue(
                        macro.sourceline,
                        "unused-param",
                        f"param '{p.name}' of macro '{macro.get('name')}' is never used",
                    )
                )
    return issues
