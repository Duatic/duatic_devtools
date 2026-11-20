# Formatter (`format-xacro`)

## Layout

| Feature | What happens | Example |
|---|---|---|
| Re-indentation | one element per line, any indent size, spaces or tabs; mixed content and `xml:space="preserve"` stay | `<a><b/></a>` → `<a>`⏎`  <b/>`⏎`</a>` |
| Empty tags | `<a></a>`, `<a> </a>`, `<a>⏎</a>` close on the same line | `<a x="1"></a>` → `<a x="1"/>` |
| Blocks | every child of the root, of a macro body and of an `xacro:if` / `unless` body: one blank line above and below. Children of other elements (e.g. `<link>`) are not blocks | |
| Equal blocks | neighbouring blocks with the same tag (same macro name for calls) stay together, if no comment is between them; `xacro:macro` definitions are always separated | |
| Comments | a comment block directly above a block stays attached: the blank goes above the comment. Comment blocks always get a blank above, none right behind a parent tag | |
| Robot and macro bodies | a blank line behind the opening tag and above the closing tag (not for `xacro:if` / `unless`) | |
| Macro calls outside of those bodies | one blank line above a call of a user macro, repeated calls of the same macro stay together | |
| Blank lines in the source | collapsed: only the rules above create blank lines | |

## Comments

| Feature | What happens |
|---|---|
| Block style | multi-line comments (and single-line ones that are too long) become `<!--`, text lines, `-->`, all at the indentation of the comment tags |
| Wrapping | text lines are wrapped to the maximum line length; lines are never joined, blank lines stay, an unbreakable word (URL) stays whole |
| Relative indentation | extra indentation of a text line is kept (also on its wrapped continuation) |
| Tabs / trailing spaces | tabs inside comments become spaces, trailing whitespace is removed |
| Short comments | `<!--   text   -->` → `<!-- text -->` |
| End-of-line comments | not allowed: moved above the element they followed (below it for a closing tag such as `</xacro:macro>`); only `nolint` stays at the end of the line |
| Comment contents | never reformatted as XML, nothing inside a comment is moved |

## Line length and wrapping

| Feature | What happens |
|---|---|
| Long tags | first attribute stays on the tag line, every other attribute goes on its own line, aligned with the first |
| Macro `params` | more than one param → one per line, aligned behind `params="`; spaces collapsed, none around `:=`, `=` becomes `:=` | `b :=2` → `b:=2` |
| `<inertia>` | too long → first `ixx iyy izz`, then the rest on a second line; if that is still too long, one attribute per line |
| Not wrappable | a single long attribute value (include paths, mesh paths, `${...}` expressions) stays |
| `nolint` comment | does not count for the line length |

## Attributes

| Feature | What happens | Example |
|---|---|---|
| Attribute order | per tag, see the table below; attributes that are not listed follow the listed ones in their original order | `<mesh scale=".." filename="..">` → `filename`, `scale` |
| `size` | always the last attribute (not for macro calls) | |
| `xmlns:*` | always last on a tag (the root tag) | `<robot xmlns:xacro=".." name="r">` → `name`, then `xmlns:xacro` |
| Macro calls | `<xacro:my_macro ...>` keep the author's attribute order | |
| Whitespace in values | runs of whitespace (spaces, tabs, newlines) become one space in **every** attribute value; string literals inside `${...}` (`'a  b'`) are kept | `a="x    y"` → `a="x y"` |
| Comparison operators | in `${...}` expressions of attribute values, `==`, `!=`, `<=` and `>=` get one space on each side; string literals and text outside `${...}` stay | `${a==b}` → `${a == b}` |
| Space around `=` | no space around the `=` of an attribute | `name = "r"` → `name="r"` |
| Numbers | see "Number normalisation" below | `0.050` → `0.05` |
| Attribute quotes | always `"`, quotes inside values become `&quot;` | |

## Top level

| Feature | What happens |
|---|---|
| Order | `<robot>` → `xacro:arg`s → `xacro:include`s → everything else; properties stay where they are |
| Args | top-level `xacro:arg` are moved right behind `<robot>` (a comment directly above an arg moves with it), original order kept |
| Includes | each `xacro:include` moves to the top of its own scope, sorted by `filename`; it never leaves its scope, comments stay | |
| Includes that stay | `filename` containing `${...}` (it may depend on a macro param or property) |
| Heading comment | a comment behind the root tag that mentions "include" stays above the include group |
| Header | everything above `<robot>` (XML declaration, license comment, ...) is never formatted, and no declaration is added |

## What is preserved

| Kept as written | Note |
|---|---|
| Non-ASCII characters | `°`, `ü`, ... (xmllint would turn them into `&#xB0;`) |
| CDATA sections | `${...}` inside CDATA is not evaluated by xacro, but is in normal text: never converted |
| Entities / DOCTYPE | `&amp;`, `&lt;`, internal `<!ENTITY>` declarations are kept, not expanded |
| Processing instructions | `<?xml-stylesheet ...?>` |
| Line endings | CRLF is converted to LF (XML normalises line breaks); a UTF-8 byte-order mark is kept |

## Number normalisation

Applied only to the attributes in the second table, and only if the **whole** value is a
whitespace separated list of plain numbers. Anything else (`${x}`, words, mixed) is left untouched,
numbers with an exponent (`1e-3`) are kept. Properties, args, macro params, macro call attributes
and text content are never touched, as they may hold strings.

| Before | After | Rule |
|---|---|---|
| `0.050` | `0.05` | trailing zeros removed |
| `007.5` | `7.5` | leading zeros removed |
| `1.0`, `100.0`, `0.0`, `-0.0` | `1`, `100`, `0`, `0` | "integer floats" become integers |
| `.5`, `5.`, `+1.0` | `0.5`, `5`, `1` | |
| `100`, `10` | unchanged | zeros of the integer part are significant |
| `0.0  0.0 1.0` | `0 0 1` | single spaces in lists |

| Tag | Numeric attributes |
|---|---|
| `origin` | `xyz rpy quat_xyzw` |
| `axis` | `xyz` |
| `mass` | `value` |
| `inertia` | `ixx iyy izz ixy ixz iyz` |
| `box` | `size` |
| `sphere` | `radius center` |
| `cylinder`, `capsule` | `radius length` |
| `mesh` | `scale` |
| `limit` | `lower upper effort velocity acceleration deceleration jerk` |
| `dynamics` | `damping friction` |
| `color` | `rgba` |
| `mimic` | `multiplier offset` |
| `safety_controller` | `soft_lower_limit soft_upper_limit k_position k_velocity` |
| `calibration` | `rising falling` |
| `joint` (SRDF `group_state`) | `value` |

## Attribute order per tag

Checked against urdfdom (URDF), srdfdom / the MoveIt Setup Assistant (SRDF), the ros2_control
`component_parser` and the xacro sources. A tag with more than one attribute and no entry here gives
a formatter warning.

| Family | Tag | Order |
|---|---|---|
| URDF | `robot` | `name version` |
| | `link`, `visual`, `collision`, `material` | `name` |
| | `joint` | `name type` (+ SRDF/ros2_control: `value role mimic read_only`) |
| | `parent`, `child` | `link` |
| | `origin` | `xyz rpy quat_xyzw` |
| | `axis` | `xyz` |
| | `limit` | `lower upper effort velocity acceleration deceleration jerk` |
| | `dynamics` | `damping friction` |
| | `calibration` | `rising falling` |
| | `mimic` | `joint multiplier offset` |
| | `safety_controller` | `soft_lower_limit soft_upper_limit k_position k_velocity` |
| | `mass` | `value` |
| | `inertia` | `ixx iyy izz ixy ixz iyz` |
| | `color` / `texture` | `rgba` / `filename` |
| | `sphere` | `center radius` |
| | `cylinder`, `capsule` | `radius length` |
| | `box` | `size` |
| | `mesh` | `filename scale` |
| SRDF | `group`, `passive_joint` | `name` |
| | `virtual_joint` | `name type parent_frame child_link` |
| | `chain` | `base_link tip_link` |
| | `group_state` | `name group` |
| | `end_effector` | `name parent_link group parent_group` |
| | `disable_collisions`, `enable_collisions` | `link1 link2 reason` |
| | `disable_default_collisions`, `link_sphere_approximation` | `link` |
| | `joint_property` | `joint_name property_name value` |
| ros2_control | `ros2_control` | `name type rw_rate is_async thread_priority` |
| | `async` | `thread_priority scheduling_policy affinity print_warnings` |
| | `actuator` | `name role read_only` |
| | `sensor`, `gpio`, `transmission`, `param` | `name` (`sensor`: `name type`) |
| | `command_interface`, `state_interface` | `name data_type size` |
| | `limits` | `enable` |
| Gazebo | `gazebo` | `reference` |
| | `plugin` | `name filename` |
| xacro | `xacro:macro` | `name params` |
| | `xacro:property` | `name value default scope lazy_eval remove` |
| | `xacro:arg` | `name default` |
| | `xacro:include` | `filename ns` |
| | `xacro:if`, `xacro:unless` | `value` |
| | `xacro:insert_block` | `name` |
| | `xacro:element`, `xacro:attribute`, `xacro:call` | `xacro:name`, `name value`, `macro` |

## Errors the formatter reports

| Situation | Output | Exit |
|---|---|---|
| Not well-formed XML (unclosed / mismatched tag, duplicate attribute, two roots, `--` in a comment, ...) | `file:line:col: parser error: ...` for every error | 2 |
| Unbound namespace prefix (`xacro:` / `gz:` without `xmlns`) | `Namespace prefix xacro on property is not defined` | 2 |
| Not UTF-8 | `file: error: not a valid UTF-8 file` | 2 |
| Unreadable file | `file: error: <reason>` | 2 |

A file with an error is never written; the other files are still processed.

## Differences to `xmllint --format` (which the formatter replaces)

| | xmllint | here |
|---|---|---|
| Output on all tested real files and ~35 tricky inputs | | identical, except the lines below |
| Non-ASCII characters in text / attributes | written as `&#xB0;` | kept |
| Undeclared namespace prefix | warning, exit 0 | hard error |
| `xml:id` duplicates | validity warning | parse error |
| Indent size | `XMLLINT_INDENT` | `--indent-size`, own indenter (same rules as libxml2) |
