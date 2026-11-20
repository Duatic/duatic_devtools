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

"""Opening tags: attribute order, number and whitespace normalisation, wrapping of long tags."""

from __future__ import annotations

import re

from duatic_xacro_hooks.formatting.layout import ATTR_RE, NAME, OPEN_TAG_RE, join_attrs, split_eol
from duatic_xacro_hooks.common import canonical_params, is_macro_call, parse_nolint, suppresses


# Attribute order per tag (checked against urdfdom and xacro). Attributes not listed follow the
# listed ones in their original order; `size` is always last, `xmlns*` behind everything.
ATTRIBUTE_ORDER: dict[str, list[str]] = {
    # URDF
    "robot": ["name", "version"],
    "link": ["name"],
    "joint": ["name", "type", "value", "role", "mimic", "read_only"],  # URDF/SRDF/ros2_control
    "parent": ["link"],
    "child": ["link"],
    "origin": ["xyz", "rpy", "quat_xyzw"],
    "axis": ["xyz"],
    "limit": ["lower", "upper", "effort", "velocity", "acceleration", "deceleration", "jerk"],
    "dynamics": ["damping", "friction"],
    "calibration": ["rising", "falling"],
    "mimic": ["joint", "multiplier", "offset"],
    "safety_controller": ["soft_lower_limit", "soft_upper_limit", "k_position", "k_velocity"],
    "mass": ["value"],
    "inertia": ["ixx", "iyy", "izz", "ixy", "ixz", "iyz"],
    "visual": ["name"],
    "collision": ["name"],
    "material": ["name"],
    "color": ["rgba"],
    "texture": ["filename"],
    "sphere": ["center", "radius"],  # URDF / SRDF
    "cylinder": ["radius", "length"],
    "capsule": ["radius", "length"],
    "box": ["size"],
    "mesh": ["filename", "scale"],
    # SRDF (srdfdom; order as written by the MoveIt Setup Assistant)
    "group": ["name"],
    "virtual_joint": ["name", "type", "parent_frame", "child_link"],
    "chain": ["base_link", "tip_link"],
    "group_state": ["name", "group"],
    "end_effector": ["name", "parent_link", "group", "parent_group"],
    "disable_collisions": ["link1", "link2", "reason"],
    "enable_collisions": ["link1", "link2", "reason"],
    "disable_default_collisions": ["link"],
    "link_sphere_approximation": ["link"],
    "passive_joint": ["name"],
    "joint_property": ["joint_name", "property_name", "value"],
    # ros2_control (hardware_interface component_parser)
    "ros2_control": ["name", "type", "rw_rate", "is_async", "thread_priority"],
    "async": ["thread_priority", "scheduling_policy", "affinity", "print_warnings"],
    "actuator": ["name", "role", "read_only"],
    "sensor": ["name", "type"],  # ros2_control / Gazebo
    "gpio": ["name"],
    "transmission": ["name"],
    "command_interface": ["name", "data_type", "size"],
    "state_interface": ["name", "data_type", "size"],
    "limits": ["enable"],
    "param": ["name"],
    # Gazebo (URDF extensions)
    "gazebo": ["reference"],
    "plugin": ["name", "filename"],
    # xacro
    "xacro:macro": ["name", "params"],
    "xacro:property": ["name", "value", "default", "scope", "lazy_eval", "remove"],
    "xacro:arg": ["name", "default"],
    "xacro:include": ["filename", "ns"],
    "xacro:if": ["value"],
    "xacro:unless": ["value"],
    "xacro:insert_block": ["name"],
    "xacro:element": ["xacro:name"],
    "xacro:attribute": ["name", "value"],
    "xacro:call": ["macro"],
}


# Attributes whose value is a list of plain numbers: normalised (see normalize_numbers).
# Only URDF/SRDF attributes, never macro params, properties or args: those may hold strings.
NUMERIC_ATTRIBUTES: dict[str, list[str]] = {
    "origin": ["xyz", "rpy", "quat_xyzw"],
    "axis": ["xyz"],
    "mass": ["value"],
    "inertia": ["ixx", "iyy", "izz", "ixy", "ixz", "iyz"],
    "box": ["size"],
    "sphere": ["radius", "center"],
    "cylinder": ["radius", "length"],
    "capsule": ["radius", "length"],
    "mesh": ["scale"],
    "limit": ["lower", "upper", "effort", "velocity", "acceleration", "deceleration", "jerk"],
    "dynamics": ["damping", "friction"],
    "color": ["rgba"],
    "mimic": ["multiplier", "offset"],
    "safety_controller": ["soft_lower_limit", "soft_upper_limit", "k_position", "k_velocity"],
    "calibration": ["rising", "falling"],
    "joint": ["value"],  # SRDF group_state joint
}


PLAIN_NUMBER_RE = re.compile(r"^([+-]?)(\d*)(?:\.(\d*))?$")


EXPONENT_NUMBER_RE = re.compile(r"^[+-]?(?:\d+\.?\d*|\.\d+)[eE][+-]?\d+$")


# A string literal inside `${...}` (`'a  b'`, or `&quot;a  b&quot;`, as double quotes are entities in an
# attribute value) is kept as it is; any other run of whitespace becomes one space
WHITESPACE_RE = re.compile(r"('[^']*'|&quot;.*?&quot;)|\s+")

# A string literal, or a comparison operator that gets one space on each side (`<` and `>` are
# entities in an attribute value)
OPERATOR_RE = re.compile(r"('[^']*'|&quot;.*?&quot;)|\s*(==|!=|&lt;=|&gt;=)\s*")


def pad_operators(value: str) -> str:
    """One space around `==`, `!=`, `<=` and `>=` in the `${...}` expressions of a value.

    String literals and everything outside `${...}` stay as they are.

    Examples::

        >>> pad_operators("${a==b and c!=1}")
        '${a == b and c != 1}'
        >>> pad_operators("x==y ${s=='a==b'}")
        "x==y ${s == 'a==b'}"
        >>> pad_operators("${a&gt;=1}")
        '${a &gt;= 1}'

    :param value: attribute value, with its whitespace already collapsed
    :returns: the value with padded operators
    """
    out = []
    i = 0
    while True:
        start = value.find("${", i)
        if start < 0:
            out.append(value[i:])
            break

        # `$${` is an escape, not an expression
        if start > 0 and value[start - 1] == "$":
            out.append(value[i : start + 2])
            i = start + 2
            continue

        # the end of the expression: its closing brace, skipping nested braces and string literals
        depth, end = 1, start + 2
        while end < len(value) and depth:
            literal = WHITESPACE_RE.match(value, end)
            if literal and literal.group(1):
                end = literal.end()
                continue
            depth += {"{": 1, "}": -1}.get(value[end], 0)
            end += 1

        # an expression that is not closed is left alone
        if depth:
            out.append(value[i:])
            break

        expression = value[start + 2 : end - 1]
        out.append(value[i : start + 2])
        out.append(OPERATOR_RE.sub(lambda m: m.group(1) or f" {m.group(2)} ", expression))
        out.append("}")
        i = end
    return "".join(out)


def normalize_number(token: str) -> str | None:
    """`0.050` -> `0.05`, `007.5` -> `7.5`, `.5` -> `0.5`, `1.0` -> `1`, `-0.0` -> `0`.

    Examples::

        >>> normalize_number("0.050")
        '0.05'
        >>> normalize_number("1.0")
        '1'
        >>> normalize_number(".5")
        '0.5'
        >>> normalize_number("${x}") is None  # not a plain number
        True

    :param token: one whitespace-free token
    :returns: the normalised number, or None if the token is not a plain number
    """
    m = PLAIN_NUMBER_RE.match(token)
    if not m or not (m[2] or m[3]):
        return None
    # strip leading zeros of the integer part and trailing zeros of the fraction
    integer, fraction = m[2].lstrip("0") or "0", (m[3] or "").rstrip("0")
    text = integer + ("." + fraction if fraction else "")

    # no negative zero
    return "0" if text == "0" else ("-" if m[1] == "-" else "") + text


def normalize_numbers(value: str) -> str:
    """Normalise a whitespace separated list of plain numbers (single spaces in between).
    Numbers with an exponent are kept, anything else (`${x}`, words) leaves the value untouched.

    Examples::

        >>> normalize_numbers("0.0  1.0 2.50")
        '0 1 2.5'
        >>> normalize_numbers("${x} 1.0")  # not only numbers
        '${x} 1.0'

    :param value: attribute value
    :returns: the normalised value, or the value unchanged if it is not only numbers
    """
    tokens = value.split()
    out = []
    for tok in tokens:
        normalized = normalize_number(tok)
        if normalized is not None:
            out.append(normalized)
        elif EXPONENT_NUMBER_RE.match(tok):
            out.append(tok)
        else:
            return value
    return " ".join(out) if tokens else value


def order_attrs(tag: str, attrs: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Sort attributes: listed ones in the defined order, then unlisted ones in their original order, then `size`, then `xmlns:*`.

    Examples::

        >>> order_attrs("mesh", [("scale", "1"), ("filename", "a")])
        [('filename', 'a'), ('scale', '1')]

    :param tag: tag name
    :param attrs: (name, value) pairs
    :returns: the sorted pairs
    """
    order = ATTRIBUTE_ORDER.get(tag, [])

    def key(item: tuple[str, str]) -> tuple[int, int]:
        """Sort key of an attribute.

        :param item: (name, value) pair
        :returns: (group, position within the group)
        """
        name = item[0]
        if name.startswith("xmlns"):
            return (3, 0)
        if name == "size":
            return (2, 0)
        if name in order:
            return (0, order.index(name))
        return (1, 0)

    return sorted(attrs, key=key)  # stable


def check_attribute_orders(body: str) -> list[tuple[int, str]]:
    """Tags with more than one attribute but no defined attribute order (first use per tag).
    `<!-- nolint -->` / `<!-- nolint: attribute-order -->` at the end of the tag's line skips it.

    :param body: formatted text below the root tag
    :returns: (line number, message) pairs
    """
    seen = set()
    problems = []

    # comments are matched too, so that a tag inside a comment is skipped
    pattern = re.compile(rf'(<!--.*?-->)|<({NAME})((?:\s+{NAME}="[^"]*")+)\s*/?>', re.S)
    for m in pattern.finditer(body):
        if m.group(1):
            continue
        tag, attrs = m.group(2), m.group(3)
        names = [a.group(1) for a in ATTR_RE.finditer(attrs)]
        if len(names) < 2 or tag in ATTRIBUTE_ORDER or tag in seen or is_macro_call(tag):
            continue

        # a nolint comment behind the tag, on the same line
        line_end = body.find("\n", m.end())
        eol = re.match(r"\s*<!--(.*?)-->", body[m.end() : line_end if line_end >= 0 else None])
        if eol:
            is_nolint, codes = parse_nolint(eol.group(1))
            if is_nolint and suppresses(codes, "attribute-order"):
                continue

        seen.add(tag)
        lineno = body.count("\n", 0, m.start()) + 1
        problems.append((lineno, f"no attribute order defined for <{tag}> ({' '.join(names)})"))
    return problems


def wrap_params(prefix: str, tokens: list[str], col: int, tail: str) -> list[str]:
    """One param per line, all aligned below each other, right behind the opening quote of
    `params="`, i.e. at col + len(prefix).

    Examples::

        >>> wrap_params('  <xacro:macro params="', ["a", "b:=1"], 2, '">')
        ['  <xacro:macro params="a', '                         b:=1">']

    :param prefix: text before the first param, ending with `params="`
    :param tokens: the params
    :param col: column at which the tag starts to be continued
    :param tail: text after the last param
    :returns: the lines
    """
    cont = " " * (col + len(prefix))
    out = [prefix + tokens[0]] + [cont + tok for tok in tokens[1:]]
    out[-1] += tail
    return out


def format_tag(line: str, max_len: int) -> list[str]:
    """A trailing nolint comment does not count for the line length and stays at the end.

    :param line: one opening tag, maybe with a trailing nolint comment
    :param max_len: maximum line length
    :returns: the lines of the tag
    """
    code, eol = split_eol(line)
    out = format_tag_code(code, max_len)
    if eol:
        out[-1] += "  " + eol
    return out


def format_tag_code(line: str, max_len: int) -> list[str]:
    """Order the attributes and normalise macro params (single spaces). If the tag is too long, keep the first attribute on
    the tag line and put every further attribute on its own line, aligned with the first.
    The params of a macro with more than one param always get one per line, aligned right behind
    `params="`.

    :param line: one opening tag without comment
    :param max_len: maximum line length
    :returns: the lines of the tag
    """
    m = OPEN_TAG_RE.match(line)
    if not m:
        return [line]
    indent, name, attrs, end = m.groups()
    is_macro = name == "xacro:macro"
    attr_list = [(a.group(1), a.group(2)) for a in ATTR_RE.finditer(attrs)]

    # macro params separated by single spaces
    if is_macro:
        attr_list = [
            (n, " ".join(canonical_params(v)) if n == "params" else v) for n, v in attr_list
        ]

    # attributes of macro calls keep the author's order
    if not is_macro_call(name):
        attr_list = order_attrs(name, attr_list)

    # numbers and whitespace of the values
    numeric = NUMERIC_ATTRIBUTES.get(name, [])
    attr_list = [
        (
            n,
            (
                normalize_numbers(v)
                if n in numeric
                else WHITESPACE_RE.sub(lambda m: m.group(1) or " ", v)
            ),
        )
        for n, v in attr_list
    ]

    # one space around comparison operators in `${...}`
    attr_list = [(n, pad_operators(v)) for n, v in attr_list]

    # fits on one line (a macro with several params always puts them below each other)
    several_params = is_macro and any(
        n == "params" and len(canonical_params(v)) > 1 for n, v in attr_list
    )
    single = f"{indent}<{name} " + " ".join(f'{n}="{v}"' for n, v in attr_list) + end
    if len(single) <= max_len and not several_params:
        return [single]

    start = f"{indent}<{name} "
    col = len(start)

    # inertia: try two lines first (diagonal terms, then the rest)
    if name == "inertia":
        diag = [(n, v) for n, v in attr_list if n in ("ixx", "iyy", "izz")]
        rest = [(n, v) for n, v in attr_list if n not in ("ixx", "iyy", "izz")]
        if len(diag) == 3 and rest:
            two = [start + join_attrs(diag), " " * col + join_attrs(rest) + end]
            if all(len(ln) <= max_len for ln in two):
                return two

    # one attribute per line, long params wrapped as well
    out: list[str] = []
    for i, (n, v) in enumerate(attr_list):
        last = i == len(attr_list) - 1
        tail = '"' + (end if last else "")
        lead = start if i == 0 else " " * col
        text = f'{n}="{v}"'
        tokens = canonical_params(v) if n == "params" and is_macro else []
        if len(tokens) > 1:
            wrapped = wrap_params(f'{n}="', tokens, col, tail)
            out.append(lead + wrapped[0])
            out += wrapped[1:]
        else:
            out.append(lead + text + (end if last else ""))
    return out
