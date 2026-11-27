# Wrapper (`duatic-clang-format`)

Runs `clang-format` with the `.clang-format` of the hook's revision, so every repository formats C++ with the same style.

## What happens

| Step | What happens |
|---|---|
| 1. Install | only with `--install-style-file`: the packaged `.clang-format` is copied into the **current directory** if it is missing or differs. pre-commit runs hooks from the repository root, so that is where it lands |
| 2. Format | `clang-format -i -style=file:<packaged .clang-format> -fallback-style=none FILE...`, with or without the flag. A `.clang-format` in a subdirectory is ignored, on purpose, to enforce one common style |

The style is installed together with the package (`data-files` in `pyproject.toml`), so it always
belongs to the same revision as the hook. Editors and plain `clang-format` calls in the repository use
the installed file as well.

## Command line

```bash
duatic-clang-format [--install-style-file] FILE...
```

| Option | Meaning |
|---|---|
| `--install-style-file` | install the packaged `.clang-format` into the current directory (see above) |
| *(anything else)* | forwarded to clang-format (files and options). The tool's `-i`, `-style=file:<packaged>` and `-fallback-style=none` are appended last, so a user cannot override them. |

| Exit code | Meaning |
|---|---|
| 0 | all files formatted / already formatted, style unchanged |
| 1 | the style was installed or changed (stage it), or clang-format failed (e.g. a file does not exist) |
| 2 | `clang-format` not found on `PATH` |

An existing `.clang-format` is **overwritten** if `--install-style-file` is passed, and the hook fails once, so stage the file. The second run passes.

## Examples

```bash
# Install the style (first run: exit 1), then format
duatic-clang-format --install-style-file a.cpp b.hpp
# Only format with the packaged style, without installing it
duatic-clang-format a.cpp b.hpp
```

## The hook (`.pre-commit-hooks.yaml`)

| Hook id | Entry | `files` | Notes |
|---|---|---|---|
| `clang-format` | `duatic-clang-format --install-style-file` | the configured extensions plus `^\.clang-format$` and `^\.pre-commit-config\.yaml$` | `language: python`; `clang-format` itself comes from `additional_dependencies` (`git+...mirrors-clang-format`), not from this package |

The id has no `duatic-` prefix, to match the upstream hook it replaces.
