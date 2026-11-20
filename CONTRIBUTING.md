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
   and a benchmark line before it merges. Every figure it quotes has its raw output committed under
   `docs/benchmarks/` with its date, commit, machine and command (`bench/record.py`; the index and the rules are in
   [docs/benchmarks/README.md](docs/benchmarks/README.md)), or says "raw data not kept" next to the figure;
   `tests/scripts/benchmarks.sh` fails otherwise.
5. **Run the gate locally** before opening a pull request:

   ```sh
   cargo fmt --all --check
   cargo clippy --workspace --all-targets -- -D warnings
   cargo test
   scripts/determinism.sh
   ```

Never commit real document pages or benchmark datasets; golden inputs are synthetic. The same goes for issues and pull
requests: do not attach a real, confidential or personal document (bank, legal, medical, identity); the bug form has a required
checkbox for it. Reproduce on a synthetic page (the generators are `tests/golden/gen_inputs.py` and `gen_pdfs.py`), or on a
public-domain or openly licensed page with its licence named, or redact the page, text layer included. Report a vulnerability
privately as [SECURITY.md](SECURITY.md) says, never in an issue.

Good places to start are the small, self-contained tasks listed in the issue tracker under the label `good first issue` when the
maintainers have filed any (none is filed yet), and the "Limitations" section of the [README](README.md#limitations): each limit
names what would have to change.

Contributions are accepted under the repository licence: unless you state otherwise, anything you
intentionally submit for inclusion is dual licensed MIT OR Apache-2.0, as the
[Licence](README.md#licence) section says, without additional terms.
