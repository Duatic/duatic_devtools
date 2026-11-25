# Checker (`check-xacro`)

Every check below. The order of the checks does not matter, and the checker does not depend on how a file is formatted. Silence a check with `--disable CODE` or a [`nolint`](#nolint) comment.
Output: `file:line: code: message`.

**Where the codes are defined:** `CODES` in
[`duatic_xacro_hooks/checks/codes.py`](../duatic_xacro_hooks/checks/codes.py) is the single list
(code and one-line description); `check-xacro --list-codes` prints it, and the tables below explain
each code. Each code is raised by one function in `duatic_xacro_hooks/checks/`, named
`check_<topic>`.

## Usage

| Option | Meaning |
|---|---|
| `--disable CODE` | do not report this check; repeatable (hard errors cannot be disabled) |
| `--list-codes` | print all check codes |

Output: `file:line: code: message`. Exit code 1 if anything was reported, else 0. The working directory matters, as included files are only found if they are below it.

## Hard errors (stop the checks of that file, cannot be silenced)

| Code | Meaning |
|---|---|
| `parse-error` | not well-formed XML, also a malformed / misplaced XML declaration (strict parse, nothing is "repaired") |
| `unbound-prefix` | a namespace prefix (`xacro:`, `gz:`, any other, also on attributes) is used without an `xmlns:` declaration in scope; the URI is not checked |

## XML file

| Code | Meaning |
|---|---|
| `xml-declaration` | the file does not start with an XML declaration |
| `xml-encoding` | a declared `encoding` is not `UTF-8` (xacro ignores the declaration and always reads UTF-8) |
| `nolint-placement` | a `nolint` comment that has no effect |
| `nolint-unknown-code` | a `nolint: code` with a code that no check has, or one that cannot be silenced (`parse-error`, `unbound-prefix`) |

## Args and includes

| Code | Meaning |
|---|---|
| `arg-placement` | `xacro:arg` not at the top of the file (only other args above it), or `$(arg x)` inside a macro (pass it as a macro param) |
| `include-without-find` | an `xacro:include` whose filename does not start with `$(find <pkg>)` |
| `named-include` | an `xacro:include` of a file whose `<robot>` has a `name` (reported at the include; the include has to resolve) |
| `include-placement` | a static include not at the top of the file (after xacro:args), or an include with `${...}` not at the top of its macro |
| `library-not-lazy` | a file without a robot `name` (a library) with a top-level element other than `xacro:macro`, `property`, `arg`, `include`: those run at include time. Use `${a if x else b}` in a property instead of `xacro:if` |

## Properties and params

| Code | Meaning |
|---|---|
| `unused-param` | a value param the macro body never uses (forwarding it with `a:=^` counts as a use; skipped if the macro calls an unknown macro or includes a file) |
| `duplicate-param` | a param name used twice (also `a` and `*a`) |

Expressions are parsed as Python to find which params a macro uses: names bound inside the
expression (comprehension variables, lambdas) and string literals do not count as uses.

## Block params (`*block`, `**block`)

| Code | Meaning |
|---|---|
| `block-order` | value params first, then `*` blocks, then `**` blocks (always in this order, all at the end of the params) |
| `block-default` | a block param with a default (`*b:=1`, `**b:=1`): xacro accepts it, ignores it, and still requires the element |
| `unused-block` | a block param that is never inserted (not reported in a macro that calls an unknown macro or includes a file) |
| `multi-block-name` | the element passed for `**name` of a called macro is not `<name>` (or at the wrong block position) |
| `unknown-param` | a call of a known macro with an attribute that is not one of its value params (block params are not attributes) |
| `missing-param` | a call of a known macro without a value param that has no default (`a`, not `a:=1`) |
| `extra-block` | a call with more elements than the macro has block params (behind the last one) |
| `missing-block` | a call without the element for one of the macro's `*` params |
| `missing-multi-block` | a call without the element for one of the macro's `**` params |

`unknown-param`, `missing-param`, `multi-block-name`, `extra-block`, `missing-block` and `missing-multi-block` need the macro definition (see below); ambiguous macro names are skipped.
Note: `*name` and `**name` both take the next child element, in order; `block-order` keeps `**name` after `*name`.

## Duplicates and others

| Code | Meaning |
|---|---|
| `duplicate-macro` | a macro name defined more than once, also with identical signatures: in this file, in a file it includes or in two different included files; reported at the later of the two (the last definition wins) |
| `duplicate-property` | a property defined twice in the same scope outside `xacro:if`/`unless` (not for `default=` / `scope=`); also across files |
| `duplicate-arg` | the same `xacro:arg` name twice; also across files |
| `duplicate-include` | the same file included twice |
| `empty-block` | a `<robot>`, macro, `xacro:if` or `xacro:unless` without any element in its body (comments do not count) |
| `mesh-uri` | a `<mesh filename>` in a `<visual>` / `<collision>` that does not start with `package://` (e.g. `file://` is not portable); a value starting with `${...}` is skipped |
| `origin-rotation` | `<origin>` with both `rpy` and `quat_xyzw` |

## Top-level and library files

A `<robot>` with a `name` marks a **top-level** file (one that is expanded on its own), one without a
`name` a **library** (one that is only included). xacro discards the `<robot>` attributes of an
included file, so a name there has no effect. `named-include` and `library-not-lazy` rely on this
convention. Where an include may be is checked by `include-placement`; a library should only define
macros, properties, args and includes, so that it does not depend on what its includer defined by then.

## Which macros a file can see

Checks that need macro definitions from other files (`unknown-param`, `missing-param`,
`multi-block-name`, `extra-block`, `missing-block`, `missing-multi-block`,
`duplicate-macro`) use the file's own macros and those of every file it includes, directly or not (also inside `xacro:if` / `unless`). `$(find pkg)` is resolved through
`package.xml` files below the current directory (the repository root under pre-commit) and the package
that contains the checked file, so no ROS installation is needed. Only the same repository is
searched: macros of other packages are unknown and their calls are skipped.

**Limitation:** includes whose path is only known at run time (`${version}`, `$(arg version)`, any
other `$(...)`) or whose package is not found are not followed. A macro that is defined only there
is unknown, so its calls are skipped by these checks: they can only report less, never more.

## What is omitted

These checks are not done here. They are left to xacro itself, which reports them when it expands
a file (for example `xacro.process_file`, as the `duatic_add_urdf_tests` / `duatic_add_srdf_test`
tests in `duatic_helpers` do), and to the URDF tests that follow:

* Undefined properties, args and macros
* Missing include files
* (In known macros) Wrong arguments
* Errors inside `${...}` expressions (syntax, types)

Includes whose path is only known at run time (`${...}`, `$(arg ...)`) are not followed, see
[above](#which-macros-a-file-can-see).

`check-xacro` covers what expansion cannot see: unused macros and component files, and style and
structure rules.

## `nolint`

| Comment | Where | Effect |
|---|---|---|
| `<!-- nolint -->` | anywhere **above** the root tag | silences every (normal) check / warning for the whole file |
| `<!-- nolint: code-a, code-b -->` | anywhere above the root tag | silences only these codes for the whole file |
| `<tag .../>  <!-- nolint -->` | at the **end of a line** | silences every check for that tag (its first line too if the tag spans lines) |
| `<tag .../>  <!-- nolint: code-a -->` | at the end of a line | silences only these codes for that tag |
| `nolint` anywhere else | own line in the body | no effect, reported as `nolint-placement` |
| `nolint: code` with a code no check has, or a hard error | anywhere | silences nothing, reported as `nolint-unknown-code` |

The keyword is case-insensitive (`NoLint`, `NOLINT`), the codes are not (`mesh-uri`, not `Mesh-URI`);
spaces around the codes are fine. A `nolint` without codes silences every check, one with several
codes silences all of them. At the end of a line it covers the tag on that line (the whole tag if it
spans several lines), not the elements inside it.

Only the hard errors (`parse-error`, `unbound-prefix`) cannot be silenced, by neither `nolint` nor
`--disable`. A `nolint` may also name `attribute-order`, the warning of the formatter.

The formatter keeps an end-of-line `nolint` at the end of its line (also when the tag is wrapped,
moved or reordered). Several of them behind one line become a single one with the union of their
codes (a `nolint` without codes wins). Any other comment behind the line moves above it.
