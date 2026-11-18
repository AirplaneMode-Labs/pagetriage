# Releasing

The release checklist mapped to the definition of done, with what is still Open before a first tag,
is [release.md](release.md); read it first and do not tag while any Blocker-for-tag row there is Open.

Nothing in this repository publishes by itself. Each step below is a deliberate command run by the person
who owns the package names and the registry accounts. The dry runs they rely on are scripts that run
locally; the `packaging` job in `.github/workflows/ci.yml` runs them on every push and pull request
(the job definition is reproduced at the end).

## What is checked before a release

| Check | Command | What it proves |
|---|---|---|
| Determinism gate | `scripts/determinism.sh` | Native, Python and WASM reports are byte-identical on every golden input; the WASM build is inside its size budget |
| Bench harness tests | `python -I -m unittest discover -s bench/tests` | The benchmark runner still agrees with the golden reports |
| Site build | `scripts/build-site.sh` | The in-browser WASM build reproduces the native fingerprints in `site/samples/samples.json` (regenerate it with `site/tools/make_samples.py` when a report changes) |
| npm tarball | `scripts/build-wasm.sh && scripts/package-npm.sh` | The tarball installs in a scratch project and `require("pagetriage")` analyses a page |
| Python wheel | `scripts/package-python.sh` | The wheel installs into a fresh virtual environment and `pagetriage_py` analyses a page |
| Crate | `cargo package -p pagetriage-core` | The core crate builds from its own tarball |
| Install proof | `scripts/prove-install.sh <wheel> <tgz> <new-scratch-dir>` | The wheel installs into a `python3 -m venv` and a `uv venv`, and the tarball into a fresh npm directory, all offline from an empty cache, each with a real call byte-equal to a golden report; the archives hold the licence files and no test data, source maps, lifecycle scripts or files over 5 MB |
| Manifest tool | `tests/scripts/release-manifest.sh`, `tests/scripts/confine.test.mjs` | `scripts/release-manifest.mjs` writes a valid unsigned manifest, refuses bad dates and output paths (Windows path forms, symlinks and junctions included: [release.md](release.md), "Output confinement"), and has no key or signing option |

## Publishing, in order

1. **Version.** Set `version` under `[workspace.package]` in `Cargo.toml`; the wheel and the npm package
   take it from there. Commit, tag `vX.Y.Z`.
2. **crates.io.** `cargo publish -p pagetriage-core`, then (once the index has it) `cargo publish -p
   pagetriage-cli`. `pagetriage-py` and `pagetriage-wasm` are marked `publish = false`: they are shipped
   as a wheel and an npm package.
3. **PyPI.** Build wheels for each platform in a manylinux container (or with `maturin-action` in CI), so
   the tags are portable (the wheel `scripts/package-python.sh` builds carries this machine's glibc tag),
   then `maturin upload` or `twine upload dist/wheels/*`. The wheel is abi3: one per platform serves
   CPython 3.9 and later.
4. **npm.** `npm publish dist/npm/pagetriage-X.Y.Z.tgz` (add `--access public` for a scoped name). The
   package name `pagetriage` has not been checked for availability.
5. **Site.** The `pages` workflow deploys `site/` on every push to `main` that touches it; it refuses to
   deploy when the WASM build stops reproducing the native fingerprints.

## Signing the manifest

`scripts/release-manifest.mjs` lists the release artifacts (npm tarball, wheels, crate tarball) with their
SHA-256 and size in an unsigned `airplanemode.manifest/0.1` and writes it inside `dist/`. It cannot sign
and never reads a key.

```sh
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) node scripts/release-manifest.mjs --out dist/release-manifest.json \
  dist/npm/pagetriage-X.Y.Z.tgz dist/wheels/*.whl
```

Signing is the owner's step, on the offline key machine, with `cp-sign` from the private `control-plane`
repository (the real key is generated there with `cp-sign keygen`; nothing here ever holds it):

```sh
cargo run -p cp-sign -- sign --key ./keys/key.secret dist/release-manifest.json --out dist/release-manifest.signed.json
cargo run -p cp-sign -- verify --pub ./keys/key.pub dist/release-manifest.signed.json
```

Publish the signed manifest and `key.pub` next to the artifacts. `--allow-test-key` exists for tests only:
the RFC 8032 test key is public, and a manifest signed with it proves the tooling, not a release. On 14 Nov
2026 a dry run with that key verified and was refused without the flag (`evidence/sprint-3/D2/dry-run-sign.log`);
it stayed outside the repository.

## When real labelled pages exist

1. Put the pages and a `labels.json` (format in the header of `bench/eval_real.py`) outside the repository
   or under `bench/data/`, which is git-ignored. They contain personal data: never commit them.
2. `python -I bench/eval_real.py PAGES_DIR --calibration-csv labelled.csv` prints precision and recall per
   kind and the page-type accuracy, and writes every finding with its raw confidence and whether it matched.
3. `python -I bench/fit_calibration.py labelled.csv > calibration_override.toml` fits the maps; check them
   on pages not used for the fit, then copy the maps into `params/calibration.toml`.
4. Replace the "synthetic only" lines in the detector docs with the measured numbers.

## What a release does not claim

Every detector from module M4 on was checked on synthetic pages only, and no confidence is calibrated
(`docs/detectors/fusion.md`). A release note should say so in the same words.

## CI job for the packaging dry runs

This is the `packaging` job in `.github/workflows/ci.yml` (actions pinned by SHA there):

```yaml
  # Packaging dry runs: the npm tarball and the Python wheel are built, installed in a scratch project,
  # and run. Nothing is published from CI.
  packaging:
    name: packaging dry runs (npm tarball, Python wheel, crate)
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: Swatinem/rust-cache@d1527c8f67ef9af357290475d4af4b0fab8f12e0 # v2.9.3
      - uses: actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0 # v7.1.0
        with:
          python-version: "3.12"
      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0
        with:
          node-version: "22"
      - name: Install pinned wasm-bindgen CLI and wasm-opt
        run: scripts/install-wasm-tools.sh
      - run: scripts/build-wasm.sh
      - name: npm tarball installs and runs under Node
        run: scripts/package-npm.sh
      - name: Python wheel installs and runs in a fresh virtual environment
        run: scripts/package-python.sh
      - name: Core crate packages and builds from its tarball
        run: cargo package -p pagetriage-core
```
