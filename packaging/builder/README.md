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

## Index what was built

```bash
./make_repo.sh
```

Runs on the host. Copies `out/` into `repo/` and indexes it with `apt-ftparchive`. Fails if the
number of package files and the number of indexed packages disagree.

## Publish signed archives

```bash
docker run --rm -it \
  -v "$PWD:/builder" \
  -v "$PWD/out:/out" \
  -v "$PWD/dist:/dist" \
  ros:jazzy-ros-base \
  /builder/publish.sh [stamp]
```

Re-running with an existing stamp switches the channel to that snapshot, which is how promotion
works. The signing key is a throwaway generated on first run.

## Checking it worked

The install checks live in `../tests/`: from the local repository, and from the signed archives.
See `../tests/README.md`.

Serving the archives is out of scope here and in `../archive/`. Both stop at producing the tree.
