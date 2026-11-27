# Quick start

## Pre-commit

```yaml
repos:
  - repo: https://github.com/Duatic/duatic_devtools
    rev: <tag>
    hooks:
      - id: clang-format  # NOTE: No 'duatic-' prefix, to match underlying hook
```

## CLI

```bash
# Install the hooks, thus the CLI tools
pip install <duatic_devtools_repo>
# clang-format with duatic style
duatic-clang-format [--install-style-file] a.cpp b.hpp c.h
```

# Documentation

| Page | Content |
|---|---|
| [duatic-clang-format](docs/duatic-clang-format.md) | clang-format wrapper with the duatic style |
