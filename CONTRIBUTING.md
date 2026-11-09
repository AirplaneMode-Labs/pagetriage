# Contributing

Thank you for considering a contribution. The [project rules](CLAUDE.md) say what a change has to
respect; the short version:

1. **Tests first.** Write the golden input, the expected report or the unit test before the code
   that makes it pass. A golden-file diff is a behaviour change and is reviewed as one; never weaken
   the determinism gate to make a change pass.
2. **No machine learning, no model files.** Hand-designed features, fixed thresholds and a few
   interpretable coefficients in `crates/pagetriage-core/params/*.toml`, each with its source.
3. **Determinism.** Use `pagetriage_core::math`, never the platform libm; `BTreeMap`, never
   `HashMap`; no clock, environment or filesystem access in the core.
4. **Docs with every detector.** A page under `docs/detectors/` with a failure gallery, a golden test
   and a benchmark line before it merges.
5. **Run the gate locally** before opening a pull request:

   ```sh
   cargo fmt --all --check
   cargo clippy --workspace --all-targets -- -D warnings
   cargo test
   scripts/determinism.sh
   ```

Never commit real document pages or benchmark datasets; golden inputs are synthetic.

Contributions are accepted under the repository licence: unless you state otherwise, anything you
intentionally submit for inclusion is dual licensed MIT OR Apache-2.0, as the
[Licence](README.md#licence) section says, without additional terms.
