# duatic_devtools

Builds and publishes `.deb` packages from Duatic's source repositories, and contains reusable cross-stack tooling for
developers.

## packaging

Full detail in `packaging/README.md`.

```bash
packaging/workspace/clone_all.sh          # clone the public source repositories
packaging/workspace/verify_isolation.sh   # check none of them can push
packaging/workspace/gen_release_set.sh    # work out the release set and the rosdep mapping
packaging/workspace/build_all.sh          # build in dependency order
packaging/archive/publish_archives.sh     # publish one signed archive root per licensable unit
```

A per-package tag like `<package>/1.0.1` builds and publishes that one package. The
orchestrator rebuilds everything in dependency order, for a new ROS distro, a new Ubuntu release or
a toolchain change.

`ROS_DISTRO_TARGET` and `OS_VERSION` select the build; jazzy and kilted both build today. The ROS
distro ends up in the Debian package name and the Ubuntu release in the archive suite, so one
archive serves every ROS distro built for that Ubuntu.

## formatting

`.pre-commit-config.yaml` defines the hooks every repository runs. Python is formatted by `black`
at 100 columns, with `flake8` ignoring what black already decides. Line endings are LF and tabs are
replaced by spaces.

This repository exports these hooks with their options in `.pre-commit-hooks.yaml`, so other
repositories reference it in their own `.pre-commit-config.yaml` instead of copying files. Pin an
exact release tag: pre-commit caches each `rev` by name and would not notice a moving tag like `v1`.
`pre-commit autoupdate` moves the pin to the latest release.

```yaml
repos:
  - repo: https://github.com/Duatic/duatic_devtools
    rev: vX.Y.Z  # an exact release tag (from the first one with .pre-commit-hooks.yaml on)
    hooks:
      # General
      - id: check-added-large-files
      - id: check-case-conflict
      - id: check-merge-conflict
      - id: check-symlinks
      - id: check-xml
      - id: check-yaml
      - id: end-of-file-fixer
      - id: mixed-line-ending
      - id: trailing-whitespace
      - id: check-byte-order-marker
      - id: remove-tabs
      - id: codespell
      - id: actionlint
      # Python and docs
      - id: check-ast
      - id: check-docstring-first
      - id: debug-statements
      - id: pyupgrade
      - id: black
      - id: flake8
      - id: doc8
      # C++ and CMake (the ament hooks need a ROS installation and run on commit only)
      - id: clang-format
      - id: ament_cppcheck
      - id: ament_cpplint
      - id: ament_lint_cmake
```

Leave out the hooks a repository does not need. Some options are fixed (the black line length, LF
line endings, the C++ style); others are defaults that a repository's `args:` replaces completely.
The header of `.pre-commit-hooks.yaml` shows how.

`CONTRIBUTING.md` covers installing and running pre-commit. CI runs the same configuration through
the pre-commit workflow of `Duatic/ci-workflows`.

`.clang-format` is the C++ style. The `clang-format` hook carries it inline, so repositories need no
copy. To use the style in an editor or with a plain `clang-format` call, copy it into the repository
root; the hook ignores that copy:

```bash
curl -fsSL https://raw.githubusercontent.com/Duatic/duatic_devtools/main/.clang-format \
  -o .clang-format
```

To change a hook, edit `.pre-commit-config.yaml`, run `pre-commit-hooks/generate_hooks.py` (needs
`pip install -e '.[dev]'`) and commit both files. CI fails if they disagree.

## Planned

- docker helper scripts
