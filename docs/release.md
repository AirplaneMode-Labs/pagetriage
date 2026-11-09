# Release checklist

One row per item of the definition of done that every Airplane Mode Labs release must meet. A row is
Done only when the Evidence column names a file or command that proves it today; anything else is
Open. Nothing may be tagged while a Blocker-for-tag row is Open. The first release will be 1.0.0; the
workspace version stays 0.1.0 until the tag commit (step 1 below), and the notes for it live under
`## [Unreleased]` in [CHANGELOG.md](../CHANGELOG.md).

Status as of 2026-11-09 (Sprint 2 CI changes included), after the move to `AirplaneMode-Labs/pagetriage`.

| # | Definition-of-done item | Status | Evidence | Owner | Blocker-for-tag |
|---|---|---|---|---|---|
| 1 | Tests written before the implementation; CI green on Linux, macOS and Windows | Done | Tests first: every detector has a golden input and expected report under `tests/golden/`, and `cargo test` plus `scripts/determinism.sh` pass locally (`evidence/sprint-1/D2/gate.log` in the workspace). CI is green on Linux, macOS and Windows in the organisation repository: the `rust` and `determinism` jobs, the `determinism` job on `windows-latest` included, first passed together on 9 Nov 2026 ([run](https://github.com/AirplaneMode-Labs/pagetriage/actions/runs/42634433346)). `scripts/install-wasm-tools.sh` has a Windows arm (x86_64 release assets of wasm-bindgen and binaryen, digests pinned in the script, fail closed on any unknown asset) and `scripts/determinism.sh` picks the venv `Scripts/` directory there; both were checked here only statically and by digest. CI also has a `deny` job (cargo-deny 0.20.2, a binary checked against a pinned SHA-256, not a Docker action; policy in `deny.toml`; the advisories leg may fail without blocking). Every checkout uses `persist-credentials: false`; `stats.yml` gives its write token only to the final push step, as a masked header | D2, then owner (push) | no |
| 2 | Benchmark on an 8 GB laptop recorded in the README | Open | README [Benchmarks](../README.md#benchmarks) carries Apple-silicon figures labelled as placeholders; the 8 GB Windows no-GPU laptop row reads "not measured". Needs `bench/` run on that hardware | owner | yes |
| 3 | README limitations section | Done | README [Limitations](../README.md#limitations): synthetic-only checks, nothing published, CI on Linux, macOS and Windows (hosted runners only), target hardware unmeasured; detector limits follow | D2 | no |
| 4 | Signed artifacts and manifest | Open | Nothing is signed. Plan: describe the wheel, npm tarball and crate tarball in an `airplanemode.manifest/0.1` manifest ([runtime/spec](https://github.com/AirplaneMode-Labs/runtime)) and sign it with `cp-sign` from control-plane, with a real key held by the owner; Sprint 2 or later, after the first real key exists | owner, D6 (tooling) | yes |
| 5 | CHANGELOG and semver tag | Open | [CHANGELOG.md](../CHANGELOG.md) exists with the 1.0.0 notes under `[Unreleased]`. The tag does not exist (`git tag` prints nothing) and must not be created until every row above and below is Done | owner | yes |
| 6 | Package installable from a clean machine | Open | Dry runs pass locally: `scripts/package-npm.sh` (tarball installs in a scratch project), `scripts/package-python.sh` (wheel installs in a fresh venv), `cargo package -p pagetriage-core`; the `packaging` CI job runs them on Ubuntu. Nothing is published to crates.io, PyPI or npm, so no clean machine can install it yet; the `@airplanemode` / `pagetriage` handles are not reserved | owner | yes |
| 7 | Short write-up | Open | No write-up exists. To be written from the measured numbers once row 2 closes; the demo page at <https://airplanemode-labs.github.io/pagetriage/> is the natural home | owner | yes |

Blocker-for-tag rows Open today: 2, 4, 5, 6, 7 (row 1 closed on 9 Nov 2026 when Windows CI first passed). Tagging v1.0.0 today would not be honest.

## Tag procedure (owner only, in this order)

Taken from [RELEASING.md](RELEASING.md); do not start it while any Blocker-for-tag row is Open.

1. **Bump the version.** Set `version = "1.0.0"` under `[workspace.package]` in `Cargo.toml` and let
   `cargo build` update `Cargo.lock`; the wheel and the npm package take the version from there.
   Move the `[Unreleased]` notes in `CHANGELOG.md` under `## [1.0.0] - YYYY-MM-DD`. This is the tag
   commit; nothing else goes in it.
2. **Run the gate** on that commit: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets
   -- -D warnings`, `cargo test`, `scripts/determinism.sh`, and the three packaging dry runs. CI must be
   green on Linux, macOS and Windows for the commit.
3. **Tag** `v1.0.0` on that commit and push the tag.
4. **crates.io.** `cargo publish -p pagetriage-core`, then `cargo publish -p pagetriage-cli`.
5. **PyPI.** Build manylinux, macOS and Windows wheels (`maturin-action` in CI or a manylinux
   container), then `maturin upload` or `twine upload dist/wheels/*`.
6. **npm.** `npm publish dist/npm/pagetriage-1.0.0.tgz` (`--access public` for a scoped name).
7. **Sign.** Write the manifest listing the three artefacts with their SHA-256 and sign it with
   `cp-sign`; publish the signed manifest with the release.
8. **Site and write-up.** The `pages` workflow deploys `site/` on the push; publish the write-up.

Do not tag until every Blocker-for-tag row is Done.
