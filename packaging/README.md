# packaging

Builds signed `.deb` packages from Duatic's source repositories and publishes them to an apt
archive.

```
builder/     one ROS package to one .deb, inside a container
workspace/   clones the source repositories, works out the release set, builds it in order
archive/     publishes one signed archive root per licensable unit
tests/       fixtures and install checks for all of the above
```

## The loop

```bash
workspace/clone_all.sh              # clone the public source repositories
workspace/verify_isolation.sh       # check none of them can push
workspace/gen_release_set.sh        # the release set and the rosdep mapping, per ROS distro
workspace/build_all.sh              # build in dependency order, through a staging repository
archive/publish_archives.sh         # publish the signed archive roots
```

`ROS_DISTRO_TARGET` and `OS_VERSION` select the build. The ROS distro ends up in the Debian package
name and the Ubuntu release in the archive suite, so one archive root serves every ROS distro built
for that Ubuntu, and a robot needs one source line whatever it runs.

Jazzy and kilted both build today, and adding a distro is running the loop again with
`ROS_DISTRO_TARGET` set. `gen_release_set.sh` writes one rosdep mapping and one package list per
distro, and `publish_archives.sh` reads every list it finds, so publishing kilted does not
un-publish jazzy. Rolling is deliberately not packaged: it moves under you, and a `.deb` published
against it goes stale without anything changing.

## Triggers

A per-package tag like `<package>/1.0.1` builds and publishes that package against the
archive. If one of its dependencies has not been published yet, `mk-build-deps` fails, which is how
"publish before dependents build" is enforced.

`workspace/build_all.sh` rebuilds the whole set in dependency order. Use it for a new ROS distro, a
new Ubuntu release, or a toolchain change.

Publishing to `nightly` is automatic. Promotion to `stable` is `aptly publish switch`, which moves
a pointer. Never rebuild to promote: a mirror holding `1.0.0` will not fetch a different `1.0.0`.

## Secrets

The scripts run `bloom`, `dpkg-buildpackage` and `aptly`, and hold no secrets. The archive signing
key lives in `archive/gnupg/` and is gitignored, as is `workspace/repos.txt`.

`workspace/README.md` lists the changes the source repositories still need.
