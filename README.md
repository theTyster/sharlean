# sharlean

Deterministic CLI (written in Lean 4, reusing the shared `Cli` package) for
scaffolding Lean projects against globally-installed shared libraries via the
sanctioned shared-clone + path-require + rewritten-manifest pattern. Avoids
per-project re-download/recompile of multi-GB deps like Mathlib.

## Prerequisites

- **`elan`** (the official Lean toolchain manager) on PATH. `sharlean` verifies this and never
  installs elan itself. Get it at <https://github.com/leanprover/elan>.

## Install

```sh
git clone https://github.com/theTyster/sharlean.git
cd sharlean && lake build     # or: make
```

Put `bin/sharlean` on PATH, e.g.:

```sh
ln -s "$(pwd)/bin/sharlean" ~/.local/bin/sharlean
```

The wrapper execs the compiled binary; if it isn't built yet, it falls back to
`lake exe` and builds on first run.

## Install root

Shared libraries live under a single root, resolved in priority order:

1. `--root <dir>` flag
2. `$SHARLEAN_HOME`
3. an existing `~/.lean` (legacy / already-populated)
4. `$XDG_DATA_HOME/lean` (default; `~/.local/share/lean`)

A `~/.lean → $XDG_DATA_HOME/lean` symlink bridges the two without migrating an existing clone.

## Commands

```sh
sharlean list                                  # installed shared libs (toolchain + git rev)
sharlean install mathlib --tag v4.29.0         # clone + cache-get + lock build dir (idempotent)
sharlean install batteries --tag v4.29.0
sharlean install <name> --git <url> --tag <t>  # any library
sharlean new <dir> --require batteries         # scaffold + build a thin project (no lake update)
sharlean new <dir> --require mathlib --lib-name Proofs   # --lib-name avoids reserved-name clashes
sharlean manifest <lib>                        # regenerate path-manifest in CWD after a version bump
sharlean unlock <name>                         # re-enable writes on a lib's build dir for upgrades
```

**One `--require` per `new`** for now. A correct multi-lib scaffold must union every lib's
transitive closure with a consistent first-wins dedup (so the generated manifest paths agree with
the `[[require]]` paths); until that lands, `new` rejects multiple requires rather than silently
mis-resolving a secondary lib. To combine libs: scaffold with the primary, add extra `require`
lines to `lakefile.toml`, and re-run `sharlean manifest <primary>`.

**Known issue: hyphens in `<dir>`.** The target directory's name is written verbatim into the
generated `lake-manifest.json`'s `"name"` field, which Lake parses as a Lean `Name` literal — a
bare hyphen (`sharlean new my-project`) fails the build with `expected a 'Name'`. Underscores work
(`sharlean new my_project`). Tracked for a fix (sanitize the manifest `name` separately from the
directory-derived module name).

## How it works / safety

- **Never runs `lake update`** in a consuming project (that re-clones every transitive dep from
  GitHub). Instead it writes a `lake-manifest.json` whose entries are all `type:"path"`, pointing at
  the shared clone's already-checked-out packages — the sanctioned "globally-shared mathlib
  installation" pattern.
- Copies each new project's `lean-toolchain` from the primary shared lib; a mismatch invalidates the
  prebuilt oleans and triggers an hours-long rebuild.
- Uses fully-expanded **absolute paths** in `require … from` (Lake does not expand `~`/env vars).
- After installing a shared lib, `chmod -R a-w`s its `.lake/build` to guard against Lake
  occasionally deleting the shared clone during checkout. `sharlean unlock` reverses this for
  upgrades.
- Builds with `LAKE_ARTIFACT_CACHE=true` (per-toolchain artifact cache, shared across workspaces).
- `sharlean` itself is built the ordinary way — `require Cli from git`, no shared clone needed
  — so a fresh clone builds standalone with nothing but `elan` on PATH.

## License

[Apache-2.0](LICENSE)
