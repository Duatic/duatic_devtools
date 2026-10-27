^^^^^^^^^
Changelog
^^^^^^^^^

1.9.0 (2026-10-27)
------------------
* feat(builder): build against packages already published in the archive (#27)
* docs(packaging): describe the stable, edge and nightly channels (#28)

1.8.0 (2026-10-27)
------------------
* fix(archive): keep each delivery in its channel, one writer at a time (#25)

1.7.0 (2026-10-27)
------------------
* feat(archive)!: stable, edge and nightly channels, kept apart (#24)

1.6.0 (2026-10-22)
------------------
* feat(archive): publish every ROS distro, each Ubuntu release in its own suite (#23)

1.5.0 (2026-10-22)
------------------
* feat(builder): build humble packages on jammy (#22)

1.4.0 (2026-10-21)
------------------
* No changes.

1.3.0 (2026-10-21)
------------------
* feat(packaging): publish a package's source beside it when it declares so (#21)
* fix(builder): record the source commit and keep a root package's changelog (#20)

1.2.0 (2026-10-18)
------------------
* feat(packaging)!: refuse open packages that depend on gated ones (#19)

1.1.0 (2026-10-14)
------------------
* feat(pre-commit): enforce LF line endings and space indentation (#17)
* feat(pre-commit): bump actionlint to v1.7.12 for schedule timezones (#18)

1.0.3 (2026-10-05)
------------------
* fix(packaging): publish signed archives with a real archive key (#16)
* ci: add title-check to pull request validation (#15)

1.0.2 (2026-09-11)
------------------
* fix: set debian frontend to non interactive (#14)

1.0.1 (2026-09-08)
------------------
* fix: derive Ubuntu version from ROS distro (#12)

1.0.0 (2026-09-03)
------------------
* ci: add release workflow for the repo (#11)
* chore: tidy up repo before public release (#10)
* chore: adapt scripts to support upcoming changes in changelogs (#9)
* ci: check the tooling on the paths each job covers (#8)
* test(packaging): add fixtures, probes and install checks (#7)
* feat(packaging): publish one signed apt archive root per entitlement (#6)
* feat(packaging): derive a release set and build it in dependency order (#5)
* feat(packaging): build a ROS package into a signed deb (#4)
* feat(release): check a pull request is consistent about its release (#2)
* chore: initialize README and .gitignore for the repo (#1)
* Initial commit
