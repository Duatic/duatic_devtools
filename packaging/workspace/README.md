# workspace

Clones a set of repositories into `src/`, works out what to release from them, and builds it in
dependency order. The clones are throwaway: nothing here is a working copy, and nothing is
committed, tagged or pushed from it.

```bash
./clone_all.sh           # clone the set in repos.txt
./verify_isolation.sh    # assert nothing here can push, and that the set is what it claims
./gen_release_set.sh     # packages.txt, the rosdep mapping and the archive lists, from src/
./build_all.sh           # build in dependency order, through staging/
```

## Isolation

Four guards, applied by `clone_all.sh` and checked by `verify_isolation.sh`:

1. Cloned over genuinely anonymous HTTPS. **This machine rewrites `https://github.com/` to SSH via
   `url.insteadOf`**, so every git call here runs with `GIT_CONFIG_GLOBAL=/dev/null
   GIT_CONFIG_SYSTEM=/dev/null`. Without that, an "anonymous" clone is authenticated as you, which
   is how eleven private repositories were once mistaken for public.
2. `origin` must remain an `https://` URL. An SSH origin carries push capability through the agent
   whatever else is set.
3. `remote.origin.pushurl` is an unroutable sentinel, so a push fails loudly.
4. `core.hooksPath` is `/dev/null`, so nothing a repository ships runs on commit.

It also fails if a package from a PRIVATE repository is routed to the public archive, and if any
repository has a commit or a tag that was not there at clone time. Nested clones (vendored sources)
are checked too.

---

# Metapackage boundaries follow the licensing boundary

A metapackage spanning a public and a licensed package drags the licensed one into a public
dependency chain, and `apt install` then fails for anyone without the licence, reported as a broken
repository rather than "not for you". So a metapackage covers packages that are served from the
same archive root, never across roots.

The rule underneath it is one-directional: **licensed may depend on public, public must never
depend on licensed.** Checked against the release set, and it holds today.

## Where a package is served from

Declared by the package, in its own `package.xml`:

```xml
<export>
  <duatic_archive_root>products/my-product</duatic_archive_root>
</export>
```

Not inferred from whether the repository is public. Those are different things: a public repository
can hold a licensed product, and today's set only makes them look aligned. `gen_release_set.sh`
reads the field and writes one list per root into `../archive/lists/`, which is what the publisher
iterates.

A package that declares nothing lands in `unrouted`, which is never published. Forgetting the field
withholds a package rather than serving it to everyone, and `verify_isolation.sh` says how many are
in that state.

## The release set

`repos.txt` is the list, hand-maintained:

```
PUBLIC   my_public_pkg    https://github.com/<org>/my_public_pkg.git
PRIVATE  my_private_pkg   https://github.com/<org>/my_private_pkg.git
```

`clone_all.sh` clones PUBLIC anonymously, with global and system git config disabled so a
`url.insteadOf` rewrite cannot turn an anonymous fetch into an authenticated one. PRIVATE entries
need a credential and are cloned only with `PRIVATE=1`. Every clone, private included, gets its
push URL pointed at an unroutable sentinel and its hooks path emptied.

It names private repositories, so it is gitignored; `repos.txt.example` documents the format.

`exclude.txt` is the same shape: packages that are in `src/` but deliberately not released, with a
reason each. Upstream packages the public index already provides go here, as do compositions that
are not deliverables. Point `gen_release_set.sh` at a different one with `EXCLUDE=<path>`. Both
files are input to the tooling rather than part of it, so what a given deployment releases is its
own decision.

The visibility column is checked, not trusted. A typo is fatal in `clone_all.sh`, and
`verify_isolation.sh` asks GitHub whether each repository really is what the file claims. That
matters because the leak check below keys on this column: a repository mistyped as PUBLIC would be
quietly exempted from it. Set `GITHUB_TOKEN` to raise the API rate limit and to tell a private
repository apart from one that does not exist; without it the check reports how many entries it
could not verify rather than passing silently. `NETWORK=0` skips it.

## A product keeps its path for life

Every product has its own archive root, permanently, whether or not it is licensed. Three states
on the same URL:

| State | Who may fetch |
|---|---|
| **Gated** | organizations holding the licence for it |
| **Early access** | named partners only |
| **Public** | anyone |

Which state a root is in is the gateway's decision, not the packaging tooling's, and changing it
moves no packages. That is the reason for one root per licensable unit: the URL a robot has in its
`sources.list` is stable for the life of the product, through every change of who may fetch it.

Separate roots also mean a partner given one product cannot enumerate the rest of the line.

## Opening a root moves no files

Because the path is permanent, making a gated root public copies nothing: no second build claims
the same version, and no client's `sources.list` changes. That last point matters wherever an agent
reconciles sources from entitlements, since a package that *moved* would have its source removed on
the next reconcile.

To serve something from a second archive as well, copy the artifact rather than rebuilding it.
`aptly repo copy` moves the pool reference so the bytes are identical, and aptly refuses a rebuild
claiming a version it already published.
