#!/usr/bin/env bash
# Sprint 7 (D2-04, S1 condition on the Dependabot updates): scripts/deps-network-check.sh fails when a network-capable crate (reqwest, hyper, ureq,
# tokio, rustls, native-tls) is in the dependency tree of pagetriage-core, normal dependencies on every target, and also dev dependencies
# (jsonschema must keep default-features = false), when the wasm_js feature of getrandom is not limited to wasm32, and reports what changed against a
# recorded tree. `cargo` is a stand-in here (no build, no network): it prints a fixed tree. DEPS_SCRIPT overrides the script under test.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SCRIPT=${DEPS_SCRIPT:-$REPO/scripts/deps-network-check.sh}
[ -f "$SCRIPT" ] || { fail "scripts/deps-network-check.sh exists"; finish; exit 1; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/repo/crates/pagetriage-core"
# the stand-in cargo: `cargo tree ... -e normal` prints $S/tree.normal, `-e normal,dev` prints $S/tree.dev; anything else fails
cat > "$S/bin/cargo" <<'SH'
#!/usr/bin/env bash
[ "$1" = tree ] || exit 2
case " $* " in
  *" normal,dev "*) cat "$TREE_DEV" ;;
  *" normal "*) cat "$TREE_NORMAL" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$S/bin/cargo"
CLEAN='pagetriage-core v1.0.0-rc.1 (/x)
libm v0.2.16
serde v1.0.229
toml v1.2.1+spec-1.1.0
lopdf v0.46.0'
printf '%s\n' "$CLEAN" > "$S/clean.normal"; printf '%s\njsonschema v0.61.2\n' "$CLEAN" > "$S/clean.dev"
cat > "$S/repo/crates/pagetriage-core/Cargo.toml" <<'T'
[target.'cfg(not(target_arch = "wasm32"))'.dependencies]
lopdf = { version = "0.46.0", default-features = false, optional = true }

[target.'cfg(target_arch = "wasm32")'.dependencies]
lopdf = { version = "0.46.0", default-features = false, features = ["wasm_js"], optional = true }

[dev-dependencies]
jsonschema = { version = "0.61.2", default-features = false }
T
run() { # run <args...>: the script in the scratch repo with the stand-in cargo; exit status echoed, output in $S/out
  env -i PATH="$S/bin:$PATH" HOME="$S" ${SYSTEMROOT:+SYSTEMROOT="$SYSTEMROOT"} TREE_NORMAL="${TN:-$S/clean.normal}" TREE_DEV="${TD:-$S/clean.dev}" DEPS_ROOT="${DR:-$S/repo}" bash "$SCRIPT" "$@" > "$S/out" 2>&1; echo $?
}
expect_eq "a clean tree passes" 0 "$(run)"
for bad in reqwest hyper ureq tokio rustls native-tls; do
  printf '%s\n%s v0.1.0\n' "$CLEAN" "$bad" > "$S/bad.normal"
  expect_eq "$bad in the normal tree fails" 1 "$(TN=$S/bad.normal run)"
  printf '%s\n%s v0.1.0\n' "$(cat "$S/clean.dev")" "$bad" > "$S/bad.dev"
  expect_eq "$bad in the dev tree (a test dependency pulling it in) fails" 1 "$(TD=$S/bad.dev run)"
done
printf '%s\nhyper-util v0.1.0\n' "$CLEAN" > "$S/near.normal"
expect_eq "a crate that merely starts with a banned name (hyper-util) fails too (it needs hyper)" 1 "$(TN=$S/near.normal run)"
printf '%s\nhyperfine-notes v0.1.0\n' "$CLEAN" > "$S/ok.normal"
expect_eq "an unrelated name is not matched by prefix alone (tokio-like names are listed, others are not)" 0 "$(TN=$S/ok.normal run)"
echo "== the wasm_js feature of getrandom stays on the wasm32 table"
sed -i.bak 's/features = \["wasm_js"\]/features = []/' "$S/repo/crates/pagetriage-core/Cargo.toml"; rm -f "$S/repo/crates/pagetriage-core/Cargo.toml.bak"
expect_eq "no wasm_js feature anywhere is fine (nothing to limit)" 0 "$(run)"
cat >> "$S/repo/crates/pagetriage-core/Cargo.toml" <<'T'
[dependencies]
lopdf = { version = "0.46.0", default-features = false, features = ["wasm_js"], optional = true }
T
expect_eq "wasm_js under plain [dependencies] fails" 1 "$(run)"
echo "== record and compare"
printf '[target.%s.dependencies]\nlopdf = { version = "0.46.0", features = ["wasm_js"] }\n' "'cfg(target_arch = \"wasm32\")'" > "$S/repo/crates/pagetriage-core/Cargo.toml"
expect_eq "--record writes the sorted tree" 0 "$(run --record "$S/before.txt")"
expect_eq "the recorded file holds the five packages" 5 "$(wc -l < "$S/before.txt" | tr -d ' ')"
printf 'pagetriage-core v1.0.0-rc.1 (/x)\nlibm v0.2.16\nserde v1.0.229\ntoml v1.2.2+spec-1.1.0\nlopdf v0.46.0\nnewcrate v0.1.0\n' > "$S/after.normal"
expect_eq "--compare exits 0 and lists a changed and an added package" 0 "$(TN=$S/after.normal run --compare "$S/before.txt")"
expect_eq "--compare names the added package" 1 "$(grep -c 'newcrate' "$S/out")"
expect_eq "--compare names the changed package" 1 "$(grep -c 'toml' "$S/out")"
expect_eq "--compare with a missing file fails" 1 "$(run --compare "$S/nope.txt")"
expect_eq "an unknown option is a usage error (exit 2)" 2 "$(run --frobnicate)"
finish
