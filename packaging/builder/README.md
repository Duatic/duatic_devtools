# builder

One ROS package in, one `.deb` out, then index it, publish it and install it.

`workspace/build_all.sh` drives these scripts over the whole release set. Use them directly when
working on a single package.

Run these from this directory.

## Build one package

```bash
docker run --rm -it \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -e ROSDEP_YAML=/rosdep/<your-mapping>.yaml \
  -v <source repository>:/src \
  -v "$PWD:/builder" \
  -v "$PWD/rosdep:/rosdep" \
  -v "$PWD/out:/out" \
  ros:jazzy-ros-base \
  /builder/build_pkg.sh <ros package name>
```

`HOST_UID` and `HOST_GID` are needed on Linux: the container runs as root, so without them the
`CHANGELOG.rst` written back into the source repository is root-owned.

`ROSDEP_YAML` is optional, and points at a mapping from ROS package name to Debian package name
for anything outside the public rosdistro index. Without it such a `<depend>` resolves to nothing,
and bloom does not treat that as an error. `rosdep/example.yaml` is the format;
`workspace/gen_release_set.sh` generates the real ones for a whole release set.

`ARCHIVE_URL` makes a published archive root an apt source for the build, for a package depending
on packages already published there. Every dependency of the package it publishes is mapped for
rosdep to its Debian name, and `mk-build-deps` installs build dependencies from it. It needs
`ARCHIVE_KEYRING`, the archive's public key mounted into the container, which apt checks the
archive's signature against. `ARCHIVE_CHANNELS` lists the channels read, by default `stable`; a
build of main reads `edge stable`, so a dependency without a build of main comes from its release.

```bash
  -e ARCHIVE_URL=<archive root URL> \
  -e ARCHIVE_KEYRING=/keys/duatic-archive.gpg \
  -e ARCHIVE_CHANNELS='edge stable' \
  -v <directory holding the key>:/keys:ro \
```

The image sets both the ROS distro and the architecture. Swap `ros:jazzy-ros-base` for
`ros:kilted-ros-base` and the matching mapping to build for kilted; the distro ends up in the
Debian package name, so the two never collide. The images are multi-arch, so an
amd64 host produces an amd64 package. For arm64, build on an arm64 machine or pass
`--platform linux/arm64`.

## Provenance

Each built package carries the commit it came from, so a `.deb` in the field can be traced back to
a tree:

```bash
dpkg -s <package> | grep Duatic-Vcs
```

A build from a tree with uncommitted changes is marked `-dirty`. If the source is not a git
checkout the field reads `unknown` rather than being omitted, so its absence means an old package
rather than a clean build.

## Source

A package declaring `<duatic_publish_source>true</duatic_publish_source>` in its `<export>` also
gets `<package>_<version>.src.tar.gz` in `out/`: the package tree as built, plus every dependency
FetchContent populated, under `_deps/`. The archive publishes it beside the package in an open
root. It is the same file whichever architecture built it.

A build that fetched anything fails unless the package declares the field, `true` or `false`:
fetched code may be GPL, which is distributed with its source.

## Builds of main

`DEB_VERSION_SUFFIX` appends to the version from `package.xml`, for a build between releases:
`DEB_VERSION_SUFFIX=+git20261027153012.ab12cd3` builds `0.4.1+git20261027153012.ab12cd3`, which sorts
after the release `0.4.1` and before the next one. It starts with `+` or `~`.

## Index what was built

```bash
./make_repo.sh
```

Runs on the host. Copies `out/` into `repo/` and indexes it with `apt-ftparchive`. Fails if the
number of package files and the number of indexed packages disagree.

## Publish signed archives

Publishing lives in `../archive/`, which produces one signed root per licensable unit. See
`../archive/README.md`.

## Checking it worked

The install check from the local repository lives in `../tests/`. See `../tests/README.md`.

Serving the archives is out of scope here and in `../archive/`. Both stop at producing the tree.
