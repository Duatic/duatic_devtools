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

"""Following `xacro:include` statements: `$(find pkg)` is resolved through `package.xml` files."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from lxml import etree

from duatic_xacro_hooks.checks.macros import collect_macros, is_skipped_dir
from duatic_xacro_hooks.checks.model import Issue, elements, tag_name

if TYPE_CHECKING:
    from collections.abc import Iterable

    from duatic_xacro_hooks.checks.model import Registry


FIND_RE = re.compile(r"\$\(find\s+([\w.-]+)\)")
PACKAGE_NAME_RE = re.compile(r"<name>\s*([^<\s]+)\s*</name>")


def find_packages(roots: Iterable[Path]) -> dict[str, Path]:
    """Package names and directories, like `$(find pkg)` knows them, without ROS.

    :param roots: directories that are searched recursively for `package.xml` files (`build`,
        `install`, `log` and hidden directories are skipped)
    :returns: package name -> directory (the first one found wins)
    """
    packages: dict[str, Path] = {}
    for root in roots:
        for directory, dirs, names in os.walk(root):
            # prune in place, so that os.walk does not descend into them
            dirs[:] = [d for d in dirs if not is_skipped_dir(d)]
            if "package.xml" in names:
                text = (Path(directory) / "package.xml").read_text(errors="ignore")
                match = PACKAGE_NAME_RE.search(text)
                if match:
                    packages.setdefault(match.group(1), Path(directory).resolve())
    return packages


@dataclass
class ParsedFile:
    """The macros that one file defines, and the files it includes."""

    macros: Registry = field(default_factory=dict)
    includes: list[Path] = field(default_factory=list)
    include_lines: list[tuple[int, str, Path]] = field(
        default_factory=list
    )  # (line, filename, file)
    robot_name: str | None = None

    # for the cross-file duplicates: what the file defines and includes at its top level, outside
    # of macros and `xacro:if` / `unless` (("property" / "arg", name) -> first line; (line, file))
    shown: str = ""
    definitions: dict[tuple[str, str], int] = field(default_factory=dict)
    top_includes: list[tuple[int, Path]] = field(default_factory=list)


class IncludeIndex:
    """Macro definitions of a file and of everything it includes, directly or not."""

    def __init__(self, packages: dict[str, Path]) -> None:
        """Create the index.

        :param packages: package name -> directory, see `find_packages`
        """
        self.packages = packages
        self._files: dict[Path, ParsedFile] = {}  # cache

    def resolve(self, filename: str, including: Path) -> Path | None:
        """The file that an `xacro:include` refers to.

        Only `$(find pkg)` of a known package and relative paths are resolved. A path with `${...}`
        or any other `$(...)` (e.g. `$(arg version)`) depends on values that are not known here.

        :param filename: the `filename` attribute of the include
        :param including: the file that contains the include
        :returns: the file, or None if it cannot be resolved statically or does not exist
        """
        if any(name not in self.packages for name in FIND_RE.findall(filename)):
            return None
        text = FIND_RE.sub(lambda m: str(self.packages[m.group(1)]), filename)
        if "${" in text or "$(" in text:
            return None

        # relative paths are relative to the including file
        path = Path(text) if Path(text).is_absolute() else including.parent / text
        path = path.resolve()
        return path if path.is_file() else None

    def _read(self, path: Path) -> ParsedFile:
        """The macros of one file and which files it includes (cached).

        :param path: the resolved path of the file
        :returns: what the file defines and includes (empty if it cannot be parsed)
        """
        if path not in self._files:
            try:
                root = etree.fromstring(path.read_bytes(), etree.XMLParser(recover=True))
            except (OSError, etree.XMLSyntaxError):
                root = None

            parsed = ParsedFile()
            if root is not None:
                # path as shown in messages: relative to the working directory if possible
                cwd = Path.cwd()
                shown = path.relative_to(cwd) if path.is_relative_to(cwd) else path
                parsed.macros = collect_macros(root, None, str(shown))
                parsed.robot_name = root.get("name") if tag_name(root) == "robot" else None

                parsed.shown = str(shown)

                # includes that can be resolved; properties (not `default=` / `scope=`, like
                # `duplicate-property`) and args at the top level
                for el in elements(root):
                    # top level: not inside a macro or `xacro:if` / `unless`
                    tag = tag_name(el)
                    top = not any(
                        tag_name(a) in ("xacro:macro", "xacro:if", "xacro:unless")
                        for a in el.iterancestors()
                    )
                    if tag == "xacro:include" and el.get("filename"):
                        target = self.resolve(el.get("filename"), path)
                        if target is not None:
                            parsed.includes.append(target)
                            parsed.include_lines.append((el.sourceline, el.get("filename"), target))
                            if top:
                                parsed.top_includes.append((el.sourceline, target))
                    elif top and el.get("name") and tag in ("xacro:property", "xacro:arg"):
                        plain = el.get("default") is None and el.get("scope") is None
                        if tag == "xacro:arg" or plain:
                            parsed.definitions.setdefault((tag[6:], el.get("name")), el.sourceline)
            self._files[path] = parsed
        return self._files[path]

    def _closure(self, path: Path) -> list[ParsedFile]:
        """The file and, directly or not, every file it includes (each once).

        :param path: the file to start from
        :returns: what each of these files defines and includes
        """
        parsed: list[ParsedFile] = []
        seen: set[Path] = set()
        stack = [path.resolve()]
        while stack:
            current = stack.pop()
            if current in seen:
                continue
            seen.add(current)
            parsed.append(self._read(current))
            stack.extend(parsed[-1].includes)
        return parsed

    def registry_of(self, path: Path) -> Registry:
        """The macro definitions that a file can see.

        Includes inside `xacro:if` / `unless` are followed too.

        :param path: the file
        :returns: macro name -> definitions, from the file and all files it includes
        """
        registry: Registry = {}
        for parsed in self._closure(path):
            for name, definitions in parsed.macros.items():
                registry.setdefault(name, []).extend(definitions)
        return registry

    def named_includes(self, path: Path) -> list[Issue]:
        """The includes of a file whose target has a robot name (`named-include`).

        A `<robot>` with a `name` marks a top-level file, which nobody should include.

        :param path: the file
        :returns: one issue per such include
        """
        return [
            Issue(
                line,
                "named-include",
                f"included file '{filename}' has a robot name ({self._read(target).robot_name}): "
                "only top-level files are named, remove the name",
            )
            for line, filename, target in self._read(path.resolve()).include_lines
            if self._read(target).robot_name is not None
        ]

    def duplicates(self, path: Path) -> list[Issue]:
        """Properties and args that a file and the files it includes define more than once.

        Only definitions at the top level of a file count (not in macros or `xacro:if` /
        `unless`), and only files included at the top level. A file included twice (also through
        two other files) counts once. A duplicate is reported once, by the file that brings both
        definitions together: at the later of the two, its own definition or its include.
        Duplicates within one file are left to `check_duplicates`.

        :param path: the file
        :returns: `duplicate-property` / `duplicate-arg` issues
        """
        own = path.resolve()

        def where(f: Path, key: tuple[str, str]) -> str:
            """`file:line` of a definition, as shown in messages."""
            return f"{self._read(f).shown}:{self._read(f).definitions[key]}"

        # in line order: the own definitions, and what each include brings (key -> files)
        sources: list[tuple[int, dict[tuple[str, str], set[Path]]]] = [
            (line, {key: {own}}) for key, line in self._read(own).definitions.items()
        ]
        for line, target in self._read(own).top_includes:
            # every file the include brings at the top level, directly or not (each once)
            brought: dict[tuple[str, str], set[Path]] = {}
            seen, stack = {own}, [target]
            while stack:
                f = stack.pop()
                if f not in seen:
                    seen.add(f)
                    stack.extend(t for _, t in self._read(f).top_includes)
                    for key in self._read(f).definitions:
                        brought.setdefault(key, set()).add(f)
            sources.append((line, brought))

        issues = []
        first: dict[tuple[str, str], Path] = {}  # key -> file of the first definition
        for line, brought in sorted(sources, key=lambda s: s[0]):
            for key, files in sorted(brought.items()):
                if key in first and first[key] not in files:
                    f = min(files)
                    kind, name = key
                    of = "" if f == own else f" of {where(f, key)} (included here)"
                    issues.append(
                        Issue(
                            line,
                            f"duplicate-{kind}",
                            f"{kind} '{name}'{of} is also defined in {where(first[key], key)}",
                        )
                    )
                first.setdefault(key, min(files))
        return issues
