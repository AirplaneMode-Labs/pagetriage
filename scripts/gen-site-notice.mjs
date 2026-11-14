// Writes the demo NOTICE: the repository NOTICE followed by one block per crate that is compiled into
// the PDF-enabled WASM build and whose `cargo metadata` licence field is exactly "MIT" (MIT requires its
// notice in every copy, and the WASM bundle is a copy). The crate list comes from cargo, never from a
// hand-kept list, so a dependency bump or a new MIT-only crate shows up without an edit.
//
//   node scripts/gen-site-notice.mjs <out-file>          demo NOTICE.txt (root NOTICE + any WASM-tree MIT block it lacks)
//   node scripts/gen-site-notice.mjs --py <out-file>     root NOTICE regenerated: the hand-written part plus one block per
//                                                        MIT-only crate in `cargo tree -p pagetriage-py` (the wheel is a copy
//                                                        too, TD-28). Idempotent. Copy the result to crates/pagetriage-py/NOTICE.
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const PY_MARKER = "Crates in the Python wheel and the WebAssembly demo that are licensed under MIT alone";
const argv = process.argv.slice(2);
const pyMode = argv[0] === "--py";
const out = pyMode ? argv[1] : argv[0];
if (!out) { console.error("usage: gen-site-notice.mjs [--py] <out-file>"); process.exit(2); }
const run = (args) => execFileSync("cargo", args, { encoding: "utf8", maxBuffer: 1 << 28 });

function treeSet(args) {
  const tree = run(["tree", "--locked", ...args, "-e", "normal", "--prefix", "none", "-f", "{p}"]);
  const set = new Set();
  for (const line of tree.split("\n")) {
    const m = /^(\S+) v(\S+)/.exec(line.trim());
    if (m) set.add(`${m[1]}@${m[2]}`);
  }
  return set;
}
const meta = JSON.parse(run(["metadata", "--locked", "--format-version", "1"]));
function mitCrates(inTree) {
  return meta.packages
    .filter((p) => inTree.has(`${p.name}@${p.version}`) && p.license === "MIT")
    .sort((a, b) => (a.name + a.version).localeCompare(b.name + b.version));
}
function block(p) {
  const dir = dirname(p.manifest_path);
  const names = readdirSync(dir).filter((f) => /^(license|licence|copying)/i.test(f) && /mit|^licen[sc]e(\.(md|txt))?$/i.test(f)).sort();
  if (names.length === 0) { console.error(`no licence file in ${dir}`); process.exit(1); }
  const body = readFileSync(join(dir, names[0]), "utf8").trim();
  const cr = body.split("\n").map((l) => l.trim()).find((l) => /^copyright\s+(\(c\)|©|\[?\d)/i.test(l) && !/yyyy|name of copyright owner/i.test(l));
  const authors = (p.authors || []).join(", ");
  const line = cr ? cr : `author from Cargo.toml: ${authors || "none listed (no copyright line in the licence file either); repository " + p.repository}`;
  return `\n=== ${p.name} ${p.version} (MIT) ===\n${line}\n\n${body}\n`;
}

if (pyMode) {
  const mit = mitCrates(treeSet(["-p", "pagetriage-py"]));
  if (mit.length === 0) { console.error("no MIT-only crates found: refusing to write an empty section"); process.exit(1); }
  let base = readFileSync("NOTICE", "utf8");
  const at = base.indexOf(PY_MARKER);
  if (at >= 0) base = base.slice(0, at).replace(/\s+$/, "");
  let text = base.replace(/\s+$/, "") + "\n\n" + PY_MARKER + "\n" + "-".repeat(PY_MARKER.length) + "\n";
  text += "Listed from `cargo metadata --locked` (licence field exactly \"MIT\"), restricted to the crates in\n";
  text += "`cargo tree --locked -p pagetriage-py -e normal` (the Python wheel); the WebAssembly demo's MIT-only\n";
  text += "crates are a subset or are added to the demo NOTICE.txt by scripts/gen-site-notice.mjs.\n";
  for (const p of mit) text += block(p);
  writeFileSync(out, text);
  console.log(`wrote ${out} (${mit.length} MIT-only crates: ${mit.map((p) => p.name).join(", ")})`);
  process.exit(0);
}

const inTree = treeSet(["-p", "pagetriage-wasm", "--target", "wasm32-unknown-unknown", "--features", "pdf"]);
const mit = mitCrates(inTree);
if (mit.length === 0) { console.error("no MIT-only crates found: refusing to write an empty section"); process.exit(1); }
let text = readFileSync("NOTICE", "utf8");
const extra = mit.filter((p) => !text.includes(`=== ${p.name} ${p.version} (MIT) ===`));
if (extra.length) {
  text += "\n\nCrates compiled into this WebAssembly demo that are licensed under MIT alone\n";
  text += "-----------------------------------------------------------------------------\n";
  text += "Listed from `cargo metadata --locked` (licence field exactly \"MIT\"), restricted to the\n";
  text += "crates in `cargo tree -p pagetriage-wasm --target wasm32-unknown-unknown --features pdf`.\n";
  for (const p of extra) text += block(p);
}
writeFileSync(out, text);
console.log(`wrote ${out} (${mit.length} MIT-only crates in the WASM tree, ${extra.length} added beyond the root NOTICE)`);
