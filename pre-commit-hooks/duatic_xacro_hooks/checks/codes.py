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

"""The check codes and their descriptions."""

CODES: dict[str, str] = {
    "arg-placement": "`xacro:arg` not at the top of the file (only other args above it), or `$(arg ...)` inside a macro",
    "block-order": "block params must come last, `*b` before `**b`",
    "block-default": "block param (`*b`, `**b`) with a default (`:=`): it has no effect, the element is required",
    "multi-block-name": "element passed for a `**b` param of a macro must be named `b`",
    "unknown-param": "call of a macro with an attribute that is not one of its params",
    "missing-param": "call of a macro without a param that has no default",
    "extra-block": "call of a macro with more elements than the macro has block params",
    "missing-block": "call of a macro without the element for one of its `*` params",
    "missing-multi-block": "call of a macro without the element for one of its `**` params",
    "unused-block": "block param of a macro that is never inserted",
    "include-without-find": "`xacro:include` whose filename does not start with `$(find <pkg>)`",
    "include-placement": "static include not at the top of the file (after xacro:args), or an include with `${...}` not at the top of its macro",
    "library-not-lazy": "file without a robot name (a library) with top-level content that is not a macro, property, arg or include",
    "named-include": "`xacro:include` of a file whose `<robot>` has a `name` (only top-level files are named)",
    "mesh-uri": "`<mesh filename>` in a `<visual>` / `<collision>` that does not start with `package://` (e.g. `file://`)",
    "origin-rotation": "`<origin>` with both `rpy` and `quat_xyzw`",
    "xml-declaration": 'file does not start with an XML declaration (`<?xml version="1.0"?>`)',
    "xml-encoding": "declared encoding is not UTF-8 (xacro only reads UTF-8)",
    "empty-block": "`robot`, macro, `xacro:if` or `xacro:unless` without any element in its body (comments do not count)",
    "unused-param": "value param of a macro that its body never uses",
    "duplicate-macro": "macro name defined more than once (in this file or another one)",
    "duplicate-property": "property defined twice in the same scope (outside xacro:if/unless, also across included files)",
    "duplicate-arg": "`xacro:arg` with the same name declared twice (also across included files)",
    "duplicate-include": "the same file included twice",
    "duplicate-param": "macro param name used twice",
    "nolint-placement": "`nolint` that has no effect (only above <robot> or at a line end works)",
    "parse-error": "file is not well-formed XML (hard error: cannot be disabled or silenced)",
    "unbound-prefix": "namespace prefix used without xmlns declaration, e.g. xacro: or gz: (hard error)",
}


HARD_ERRORS: set[str] = {
    "parse-error",
    "unbound-prefix",
}  # no nolint, no --disable, no other checks
