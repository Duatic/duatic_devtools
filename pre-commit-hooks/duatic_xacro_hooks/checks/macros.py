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

"""Macro definitions across files, and the checks of macros: block params, duplicates, empty ones."""

from __future__ import annotations

import os
from fnmatch import fnmatchcase
from itertools import takewhile
from pathlib import Path
from typing import TYPE_CHECKING

from lxml import etree

from duatic_xacro_hooks.checks.model import (
    Issue,
    has_unseen_code,
    MacroDef,
    children,
    elements,
    enclosing_macro,
    parse_params,
    tag_name,
)
from duatic_xacro_hooks.common import is_macro_call

if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator, Sequence

    from duatic_xacro_hooks.checks.model import Element, Registry


def is_skipped_dir(d: str) -> bool:
    """Is a directory one that never holds sources?

    Copies in build or install spaces, virtual environments and caches would be duplicates.

    :param d: the name of the directory
    :returns: True if it matches one of the patterns: hidden, `*build*`, `install`, `log`,
        `*cache*`, `*.egg-info`, `node_modules`, `site-packages`, `venv`
    """
    patterns: tuple[str, ...] = (".*", "*build*", "install", "log", "*cache*", "*.egg-info")
    patterns += ("node_modules", "site-packages", "venv")

    return any(fnmatchcase(d, pattern) for pattern in patterns)


def iter_xacro_files(directory: Path) -> Iterator[Path]:
    """All `*.xacro` below directory (sorted), without build / install / hidden directories.

    :param directory: directory to search
    :returns: the files
    """
    for root, dirs, names in os.walk(directory):
        dirs[:] = sorted(d for d in dirs if not is_skipped_dir(d))
        for name in sorted(names):
            if name.endswith(".xacro"):
                yield Path(root) / name


def load_registry(paths: Iterable[Path], registry: Registry | None = None) -> Registry:
    """Macro definitions of files / directories (recursively `*.xacro`).

    :param paths: files or directories
    :param registry: registry to extend (default: a new one)
    :returns: the registry
    """
    registry = {} if registry is None else registry

    files = []
    for path in map(Path, paths):
        files += list(iter_xacro_files(path)) if path.is_dir() else [path]

    for f in files:
        # lenient parse: unreadable or broken files just contribute no macros
        try:
            root = etree.fromstring(f.read_bytes(), etree.XMLParser(recover=True))
        except (OSError, etree.XMLSyntaxError):
            continue
        if root is not None:
            collect_macros(root, registry, str(f))
    return registry


def collect_macros(root: Element, registry: Registry | None = None, path: str = "") -> Registry:
    """macro name -> list of MacroDef (a definition seen twice, same path and line, counts once).

    :param root: root element of the file
    :param registry: registry to extend (default: a new one)
    :param path: name of the file, stored in the definitions
    :returns: the registry
    """
    registry = {} if registry is None else registry
    for el in elements(root):
        if tag_name(el) == "xacro:macro" and el.get("name"):
            d = MacroDef(path, el.sourceline, tuple(parse_params(el.get("params"))))
            defs = registry.setdefault(el.get("name"), [])
            if not any((o.path, o.line) == (d.path, d.line) for o in defs):
                defs.append(d)
    return registry


def check_duplicates(
    root: Element,
    brought: Sequence[tuple[int, str, Registry]] = (),
    path: str = "",
) -> list[Issue]:
    """Macros, properties, args and includes that are defined more than once (`duplicate-*`).

    :param root: root element of the file
    :param brought: (line, filename, macros) of each include of the file, see `brought_macros`
    :param path: name of the file, stored in the macro definitions
    :returns: the issues found
    """
    issues = []

    # macros: two of this file are both reported
    own = [
        (el.sourceline, el.get("name"))
        for el in elements(root)
        if tag_name(el) == "xacro:macro" and el.get("name")
    ]
    for line, name in own:
        issues += [
            Issue(
                line,
                "duplicate-macro",
                f"{path}:{other} and {path}:{line} both define macro '{name}'",
            )
            for other, other_name in own
            if other_name == name and other != line
        ]

    # macros of this file and of its includes: the last definition wins in xacro, so a duplicate is
    # reported at the later of the two (its own macro or its include); a file reached twice is no
    # duplicate
    sources: list[tuple[int, str, dict[str, set[tuple[str, int]]]]] = [
        (line, "", {name: {(path, line)}}) for line, name in own
    ] + [
        (line, filename, {n: {(d.path, d.line) for d in ds} for n, ds in registry.items()})
        for line, filename, registry in brought
    ]
    earliest: dict[str, tuple[str, int]] = {}
    for line, filename, defined in sorted(sources, key=lambda s: s[0]):
        for name, sites in sorted(defined.items()):
            if name not in earliest:
                earliest[name] = min(sites)
            elif earliest[name] not in sites and not (not filename and earliest[name][0] == path):
                before = earliest[name]
                here = min(sites)
                # two files that the checked one brings together, or the checked file and another
                importer = "" if path in (before[0], here[0]) else f" (both imported by {path})"
                issues.append(
                    Issue(
                        line,
                        "duplicate-macro",
                        f"{before[0]}:{before[1]} and {here[0]}:{here[1]} "
                        f"both define macro '{name}'{importer}",
                    )
                )

    # properties: same scope (macro or robot level), unconditional, no default/scope attribute
    seen: dict = {}
    for el in elements(root):
        if tag_name(el) != "xacro:property" or not el.get("name"):
            continue
        if el.get("default") is not None or el.get("scope") is not None:
            continue
        scope = enclosing_macro(el)

        # inside an xacro:if / xacro:unless below the scope: may be defined twice on purpose
        stop = scope if scope is not None else root
        if any(
            tag_name(anc) in ("xacro:if", "xacro:unless")
            for anc in takewhile(lambda anc: anc is not stop, el.iterancestors())
        ):
            continue

        key = (id(scope), el.get("name"))
        if key in seen:
            issues.append(
                Issue(
                    el.sourceline,
                    "duplicate-property",
                    f"property '{el.get('name')}' is already defined in line {seen[key]}",
                )
            )
        else:
            seen[key] = el.sourceline

    # args and includes: anywhere in the file
    for tag, attr, code in (
        ("xacro:arg", "name", "duplicate-arg"),
        ("xacro:include", "filename", "duplicate-include"),
    ):
        first: dict = {}
        for el in elements(root):
            if tag_name(el) == tag and el.get(attr):
                if el.get(attr) in first:
                    issues.append(
                        Issue(
                            el.sourceline,
                            code,
                            f"'{el.get(attr)}' is already declared in line {first[el.get(attr)]}",
                        )
                    )
                else:
                    first[el.get(attr)] = el.sourceline

    # params inside one macro
    for macro in (el for el in elements(root) if tag_name(el) == "xacro:macro"):
        names = set()
        for p in parse_params(macro.get("params")):
            if p.name in names:
                issues.append(
                    Issue(
                        macro.sourceline,
                        "duplicate-param",
                        f"macro '{macro.get('name')}': param '{p.name}' appears twice",
                    )
                )
            names.add(p.name)
    return issues


EMPTY_BLOCK_TAGS = {"robot", "xacro:macro", "xacro:if", "xacro:unless"}


def check_empty_blocks(root: Element) -> list[Issue]:
    """The robot, macros, `xacro:if` and `xacro:unless` without any element in their body (`empty-block`).
    Comments do not count as content.

    :param root: root element of the file
    :returns: the issues found
    """
    issues = []
    for el in elements(root):
        tag = tag_name(el)
        if tag in EMPTY_BLOCK_TAGS and not children(el):
            what = f"macro '{el.get('name')}'" if tag == "xacro:macro" else f"<{tag}>"
            issues.append(Issue(el.sourceline, "empty-block", f"{what} has an empty body"))
    return issues


def check_blocks(root: Element, registry: Registry) -> list[Issue]:
    """Block params of macro definitions (`*name`, `**name`): order, defaults and unused blocks.

    A block that is never inserted is not reported in a macro that calls an unknown macro or includes
    a file: that code may insert it (xacro scopes dynamically).

    :param root: root element of the file
    :param registry: macro definitions of all known files
    :returns: the issues found
    """
    issues = []
    for macro in (el for el in elements(root) if tag_name(el) == "xacro:macro"):
        mname = macro.get("name")
        params = parse_params(macro.get("params"))

        # value params must come first, and `*` params before `**` params
        seen_block = None
        seen_multi = False
        for p in params:
            if p.kind == "value" and seen_block:
                issues.append(
                    Issue(
                        macro.sourceline,
                        "block-order",
                        f"macro '{mname}': param '{p.raw}' behind block param '{seen_block}'",
                    )
                )
            if p.kind != "value":
                seen_block = seen_block or p.raw
                if p.kind == "block" and seen_multi:
                    issues.append(
                        Issue(
                            macro.sourceline,
                            "block-order",
                            f"macro '{mname}': '*' param '{p.raw}' behind a '**' param",
                        )
                    )
                seen_multi |= p.kind == "multi"

        # a default has no effect on a block: xacro still requires the element
        for p in params:
            if p.kind != "value" and "=" in p.raw:
                issues.append(
                    Issue(
                        macro.sourceline,
                        "block-default",
                        f"macro '{mname}': block param '{p.raw}' has a default, which has no effect",
                    )
                )

        # every block param must be inserted somewhere in the body (unless an unknown macro might)
        if has_unseen_code(macro, registry):
            continue
        inserted = {  # `*name` is tolerated here: xacro itself rejects it when expanded
            (el.get("name") or "").lstrip("*")
            for el in elements(macro)
            if tag_name(el) == "xacro:insert_block"
        }
        for p in params:
            if p.kind != "value" and p.name not in inserted:
                issues.append(
                    Issue(
                        macro.sourceline,
                        "unused-block",
                        f"macro '{mname}': block param '{p.raw}' is never inserted",
                    )
                )
    return issues


def check_calls(root: Element, registry: Registry) -> list[Issue]:
    """Calls of known macros: attributes must be value params, elements must be block params.

    :param root: root element of the file
    :param registry: macro definitions of all known files
    :returns: the issues found
    """
    issues = []
    for call in elements(root):
        # only calls of macros with exactly one known signature
        tag = tag_name(call)
        if not tag or not is_macro_call(tag):
            continue
        sigs = {d.params for d in registry.get(tag[len("xacro:") :], [])}
        if len(sigs) != 1:  # unknown macro (xacro reports it) or ambiguous definitions
            continue
        macro_name = tag[len("xacro:") :]
        params = next(iter(sigs))
        blocks = [p for p in params if p.kind != "value"]
        values = {p.name for p in params if p.kind == "value"}

        # attributes are value params
        for attribute in call.attrib:
            if attribute not in values:
                message = f"call of macro '{macro_name}' sets '{attribute}', which is not a param"
                issues.append(Issue(call.sourceline, "unknown-param", message))

        # value params without default must be set
        for param in params:
            if param.required and param.name not in call.attrib:
                message = (
                    f"call of macro '{macro_name}' lacks the param '{param.name}' (no default)"
                )
                issues.append(Issue(call.sourceline, "missing-param", message))

        # child elements are the blocks; directives among them make the count unknowable
        kids = children(call)
        kid_names = [tag_name(k) for k in kids]
        if any(name and name.startswith("xacro:") for name in kid_names):
            continue

        # blocks are matched to block params in order
        for i, param in enumerate(blocks):
            if i >= len(kids):
                if param.kind == "multi":
                    code, what = "missing-multi-block", f"<{param.name}> for '{param.raw}'"
                else:
                    code, what = "missing-block", f"an element for '{param.raw}'"
                message = f"call of macro '{macro_name}' lacks {what}"
                issues.append(Issue(call.sourceline, code, message))
            elif param.kind == "multi" and kid_names[i] != param.name:
                if param.name in kid_names:
                    msg = (
                        f"<{param.name}> for '{param.raw}' of macro '{macro_name}' is block "
                        f"{kid_names.index(param.name) + 1}, expected block {i + 1}"
                    )
                else:
                    msg = f"<{kid_names[i]}> passed for '{param.raw}' of macro '{macro_name}', expected <{param.name}>"
                issues.append(Issue(kids[i].sourceline, "multi-block-name", msg))

        # elements behind the last block param
        for extra in kids[len(blocks) :]:
            message = (
                f"<{tag_name(extra)}> is an extra block: macro '{macro_name}' has no param for it"
            )
            issues.append(Issue(extra.sourceline, "extra-block", message))
    return issues
