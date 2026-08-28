# builder

One ROS package in, one `.deb` out, then index it, publish it and install it.

`workspace/build_all.sh` drives these scripts over the whole release set. Use them directly when
working on a single package.

Paths below assume the repository is at `~/duatic_devtools`.

## Build one package

```bash
docker run --rm -it \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  -e ROSDEP_YAML=/rosdep/duatic-jazzy.yaml \
  -v <source repository>:/src \
  -v ~/duatic_devtools/packaging/builder:/builder \
  -v ~/duatic_devtools/packaging/builder/rosdep:/rosdep \
  -v ~/duatic_devtools/packaging/builder/out:/out \
  ros:jazzy-ros-base \
  /builder/build_pkg.sh duatic_helper_msgs
```

`HOST_UID` and `HOST_GID` are needed on Linux: the container runs as root, so without them the
`CHANGELOG.rst` written back into the source repository is root-owned.

`ROSDEP_YAML` is optional. Without it a `<depend>` on another Duatic package resolves to nothing,
and bloom does not treat that as an error.

The image sets both the ROS distro and the architecture. Swap `ros:jazzy-ros-base` for
`ros:kilted-ros-base` and the matching `rosdep/duatic-kilted.yaml` to build for kilted; the distro
ends up in the Debian package name, so the two never collide. The images are multi-arch, so an
amd64 host produces an amd64 package. For arm64, build on an arm64 machine or pass
`--platform linux/arm64`.

## Provenance

Each built package carries the commit it came from, so a `.deb` in the field can be traced back to
a tree:

```bash
dpkg -s ros-jazzy-duatic-helper-msgs | grep Duatic-Vcs
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
  -v ~/duatic_devtools/packaging/builder:/builder \
  -v ~/duatic_devtools/packaging/builder/out:/out \
  -v ~/duatic_devtools/packaging/builder/dist:/dist \
  ros:jazzy-ros-base \
  /builder/publish.sh [stamp]
```

Re-running with an existing stamp switches the channel to that snapshot, which is how promotion
works. The signing key is a throwaway generated on first run.

## Checking it worked

The install checks live in `../tests/`: from the local repository, from the signed archives, and
over HTTPS with and without a client certificate. See `../tests/README.md`.

Serving over HTTPS is `../archive/`, which runs Caddy in a container. Nothing here configures a web
server on the host.
