// Writes the NOTICE of the pagetriage command-line tool: the hand-written part of the repository NOTICE followed by one
// block per crate in the CLI's dependency tree whose `cargo metadata` licence field is exactly "MIT". A CLI binary is a
// copy of every crate linked into it and MIT requires its notice in every copy (BUG-T3-S4-19). The tree is the one for
// ALL targets (`cargo tree --locked -p pagetriage-cli --target all -e normal`), because a binary built on Linux or Windows
// links crates that a macOS build does not: crunchy 0.2.4 is MIT-only and is in the tree only with `--target all`
// (BUG-T3-S4-21). The crate list comes from cargo, never from a hand-kept list, so a dependency bump or a new MIT-only
// crate shows up without an edit; tests/scripts/notice-cli.sh checks the committed file against cargo.
//
//   node scripts/notice-cli.mjs <out-file>            write the NOTICE (copy it to crates/pagetriage-cli/NOTICE)
//   node scripts/notice-cli.mjs --check [file]        exit 1 unless <file> (default crates/pagetriage-cli/NOTICE) is
//                                                     byte for byte what would be written now
//
// Run from the repository root. Idempotent: the hand-written part is the repository NOTICE cut before the
// Python-wheel marker, so regenerating the root NOTICE with gen-site-notice.mjs --py does not change this file.
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const PY_MARKER = "Crates in the Python wheel and the WebAssembly demo that are licensed under MIT alone";
const CLI_MARKER = "Crates in the pagetriage command-line tool that are licensed under MIT alone";
const DEFAULT_FILE = "crates/pagetriage-cli/NOTICE";

const argv = process.argv.slice(2);
const check = argv[0] === "--check";
const target = check ? (argv[1] ?? DEFAULT_FILE) : argv[0];
if (!target) {
  console.error("usage: notice-cli.mjs <out-file> | --check [file]");
  process.exit(2);
}
const run = (args) => execFileSync("cargo", args, { encoding: "utf8", maxBuffer: 1 << 28 });

const tree = run(["tree", "--locked", "-p", "pagetriage-cli", "--target", "all", "-e", "normal", "--prefix", "none", "-f", "{p}"]);
const inTree = new Set();
for (const line of tree.split("\n")) {
  const m = /^(\S+) v(\S+)/.exec(line.trim());
  if (m) inTree.add(`${m[1]}@${m[2]}`);
}
const meta = JSON.parse(run(["metadata", "--locked", "--format-version", "1"]));
const mit = meta.packages
  .filter((p) => inTree.has(`${p.name}@${p.version}`) && p.license === "MIT")
  .sort((a, b) => (a.name + a.version).localeCompare(b.name + b.version));
if (mit.length === 0) {
  console.error("no MIT-only crates found: refusing to write an empty section");
  process.exit(1);
}

function block(p) {
  const dir = dirname(p.manifest_path);
  const names = readdirSync(dir).filter((f) => /^(license|licence|copying)/i.test(f) && /mit|^licen[sc]e(\.(md|txt))?$/i.test(f)).sort();
  if (names.length === 0) {
    console.error(`no licence file in ${dir}`);
    process.exit(1);
  }
  const body = readFileSync(join(dir, names[0]), "utf8").trim();
  const cr = body
    .split("\n")
    .map((l) => l.trim())
    .find((l) => /^copyright\s+(\(c\)|©|\[?\d)/i.test(l) && !/yyyy|name of copyright owner/i.test(l));
  const authors = (p.authors || []).join(", ");
  const line = cr ? cr : `author from Cargo.toml: ${authors || "none listed (no copyright line in the licence file either); repository " + p.repository}`;
  return `\n=== ${p.name} ${p.version} (MIT) ===\n${line}\n\n${body}\n`;
}

let base = readFileSync("NOTICE", "utf8");
const at = base.indexOf(PY_MARKER);
if (at >= 0) base = base.slice(0, at);
let text = base.replace(/\s+$/, "") + "\n\n" + CLI_MARKER + "\n" + "-".repeat(CLI_MARKER.length) + "\n";
text += "Listed from `cargo metadata --locked` (licence field exactly \"MIT\"), restricted to the crates in\n";
text += "`cargo tree --locked -p pagetriage-cli --target all -e normal`: the tree for every target, so that a build on\n";
text += "Linux or Windows is covered as well as one on macOS.\n";
for (const p of mit) text += block(p);

if (check) {
  let have = null;
  try {
    have = readFileSync(target, "utf8");
  } catch {
    // reported below
  }
  if (have === text) {
    console.log(`${target} is up to date (${mit.length} MIT-only crates)`);
    process.exit(0);
  }
  console.error(`${target} is ${have === null ? "missing" : "stale"}: run node scripts/notice-cli.mjs ${DEFAULT_FILE}`);
  process.exit(1);
}
writeFileSync(target, text);
console.log(`wrote ${target} (${mit.length} MIT-only crates: ${mit.map((p) => p.name).join(", ")})`);
