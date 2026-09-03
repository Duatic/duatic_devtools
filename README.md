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

`.pre-commit-config.yaml` is the configuration every repository runs. Python is formatted by `black`
at 100 columns, with `flake8` ignoring what black already decides.

`pre-commit` reads a config only from the root of the repository being checked, so repositories copy
the file in rather than reference it. Pin a tag rather than `main` to hold a repository to a known
set of rules:

```bash
curl -fsSL https://raw.githubusercontent.com/Duatic/duatic_devtools/main/.pre-commit-config.yaml \
  -o .pre-commit-config.yaml
```

`CONTRIBUTING.md` covers installing and running it. CI runs the same hooks through.

`.clang-format` is the C++ style, copied in the same way:

```bash
curl -fsSL https://raw.githubusercontent.com/Duatic/duatic_devtools/main/.clang-format \
  -o .clang-format
```

## Planned

- docker helper scripts
