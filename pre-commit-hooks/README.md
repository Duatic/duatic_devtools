# duatic_xacro_hooks

Two [pre-commit](https://pre-commit.com) hooks for xacro files (`*.xacro`, also `*.urdf.xacro`,
`*.srdf.xacro`, ...). They need only Python ≥ 3.10 and [`lxml`](https://lxml.de): no `xmllint`, no ROS installation. The
two hooks work independently of each other.

| Hook / command | What it does | Changes files |
|---|---|---|
| `format-xacro` | indentation, blank lines, comments, line length, attribute order, numbers, includes | yes (in place) |
| `check-xacro` | what a formatter cannot fix: undefined properties, bad args, block params, duplicates, ... | no |

## Quick start

```yaml
repos:
  - repo: https://github.com/Duatic/duatic_devtools
    rev: <tag>
    hooks:
      - id: check-xacro       # first: checks the files as written
      - id: format-xacro      # then: formats them
```

```bash
pip install .                                   # from the repository root
format-xacro a.urdf.xacro b.xacro    # formats the files in place; --check in CI
check-xacro $(git ls-files '*.xacro')
check-xacro --list-codes
```

## Documentation

| Page | Content |
|---|---|
| [usage](docs/usage.md) | the hooks, all command line options, exit codes |
| [format-xacro](docs/format-xacro.md) | every formatting rule, number normalisation, attribute order per tag, errors |
| [check-xacro](docs/check-xacro.md) | every check with its **code**, grouped by topic |
