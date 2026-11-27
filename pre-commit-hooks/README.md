# Quick start

## Pre-commit

```yaml
repos:
  - repo: https://github.com/Duatic/duatic_devtools
    rev: <tag>
    hooks:
      - id: clang-format  # NOTE: No 'duatic-' prefix, to match underlying hook
      - id: check-xacro       # first: checks the files as written
      - id: format-xacro      # then: formats them
```

## CLI

```bash
# Install the hooks, thus the CLI tools
pip install <duatic_devtools_repo>
# clang-format with duatic style
duatic-clang-format [--install-style-file] a.cpp b.hpp c.h
# xacro formatting
format-xacro [<args>] a.urdf.xacro b.xacro
# xacro checking
check-xacro [--disable <CODE>] a.urdf.xacro b.xacro
```

# Documentation

| Page | Content |
|---|---|
| [duatic-clang-format](docs/duatic-clang-format.md) | clang-format wrapper with the duatic style |
| [check-xacro](docs/check-xacro.md) | every check with its **code**, grouped by topic |
| [format-xacro](docs/format-xacro.md) | every formatting rule, number normalisation, attribute order per tag, errors |
