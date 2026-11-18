#!/usr/bin/env bash
# docs/wasm-api.md documents the call dockit makes (analyse_pdf_structure) and the fields it reads. This fails
# when the document names something the code no longer has, or leaves out something the code has:
#
#   - every path in the `wasm-api:fields` block exists in schema/pagetriage-structure-0.1.schema.json, and the ones
#     marked `nullable` really are nullable there;
#   - the `wasm-api:states` block equals the text_layer.state enum of that schema (both directions);
#   - every `key = value` in the `wasm-api:limits` block equals the same key in
#     crates/pagetriage-core/params/structural_limits.toml, and the six limits the document explains are all present;
#   - every name in the `wasm-api:exports` block is a `pub fn` in crates/pagetriage-wasm/src/lib.rs, and
#     analyse_pdf_structure sits behind `#[cfg(feature = "pdf")]`;
#   - the build command in the document is the one scripts/build-wasm.sh accepts;
#   - every number in the `wasm-api:bench` block equals the row of docs/benchmarks/wasm-structure.csv it names, and every
#     CSV row names its machine, browser, commit, build and command and says "not measured on 8 GB", and the decompression
#     bomb row is a bounded, truncated, degraded result, not a hang.
#
# Each input can be pointed elsewhere (WASM_API_DOC, STRUCTURE_SCHEMA, STRUCTURAL_LIMITS, WASM_LIB_RS, BENCH_CSV); the red log
# for the drift test runs it against a schema copy with one documented field renamed, which must fail.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

command -v node >/dev/null || { fail "node not found: wasm-api-doc.sh cannot run (Node 22 is required)"; finish; exit 1; }
export DOC=${WASM_API_DOC:-$REPO/docs/wasm-api.md}
export SCHEMA=${STRUCTURE_SCHEMA:-$REPO/schema/pagetriage-structure-0.1.schema.json}
export LIMITS=${STRUCTURAL_LIMITS:-$REPO/crates/pagetriage-core/params/structural_limits.toml}
export LIBRS=${WASM_LIB_RS:-$REPO/crates/pagetriage-wasm/src/lib.rs}
export BUILDSH=${BUILD_WASM_SH:-$REPO/scripts/build-wasm.sh}
export BENCH_CSV=${BENCH_CSV:-$REPO/docs/benchmarks/wasm-structure.csv}

expect_eq "docs/wasm-api.md exists" yes "$([ -f "$DOC" ] && echo yes || echo no)"
if [ ! -f "$DOC" ]; then finish; exit 1; fi

CHECKDIR=$(mktemp -d)
CHECK=$CHECKDIR/check.mjs
trap 'rm -rf "$CHECKDIR"' EXIT
cat > "$CHECK" <<'JS'
import { readFileSync } from "node:fs";
const doc = readFileSync(process.env.DOC, "utf8");
const schema = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
const limitsToml = readFileSync(process.env.LIMITS, "utf8");
const libRs = readFileSync(process.env.LIBRS, "utf8");
const buildSh = readFileSync(process.env.BUILDSH, "utf8");
const csvText = readFileSync(process.env.BENCH_CSV, "utf8");
const out = [];
const ok = (m) => out.push(`ok   - ${m}`);
const bad = (m) => out.push(`FAIL - ${m}`);
const check = (cond, m) => (cond ? ok(m) : bad(m));

// A block is the lines of the fenced code block that sits between the two marker comments.
function block(name) {
  const m = new RegExp(`<!-- wasm-api:${name}:start -->\\s*\`\`\`[a-z]*\\n([\\s\\S]*?)\`\`\`\\s*<!-- wasm-api:${name}:end -->`).exec(doc);
  if (!m) { bad(`block wasm-api:${name} is present in the document`); return null; }
  return m[1].split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
}

// ---- schema walking --------------------------------------------------------------------------------------
const deref = (n) => {
  while (n && n.$ref) {
    const name = n.$ref.replace(/^#\/(\$defs|definitions)\//, "");
    n = (schema.$defs || schema.definitions || {})[name];
  }
  return n;
};
// every concrete variant of a node: itself, and what its anyOf / oneOf / allOf point at
function variants(n) {
  n = deref(n);
  if (!n || typeof n !== "object") return [];
  const vs = [n];
  for (const k of ["anyOf", "oneOf", "allOf"]) for (const v of n[k] || []) vs.push(...variants(v));
  return vs;
}
const isNullable = (n) =>
  variants(n).some((v) => v.type === "null" || (Array.isArray(v.type) && v.type.includes("null")) || (v.enum || []).includes(null));
function step(node, seg) {
  const m = /^([A-Za-z_][A-Za-z0-9_]*)(\[\])?$/.exec(seg);
  if (!m) return undefined;
  let next;
  for (const v of variants(node)) if (v.properties && Object.hasOwn(v.properties, m[1])) next = v.properties[m[1]];
  if (!next) return undefined;
  if (m[2]) {
    let items;
    for (const v of variants(next)) if (v.items) items = v.items;
    return items;
  }
  return next;
}
function resolvePath(path) {
  let node = schema;
  for (const seg of path.split(".")) {
    node = step(node, seg);
    if (node === undefined) return undefined;
  }
  return node;
}
function enumValues(node) {
  const vals = new Set();
  for (const v of variants(node)) {
    for (const e of v.enum || []) if (e !== null) vals.add(e);
    if (typeof v.const === "string") vals.add(v.const);
  }
  return vals;
}

// ---- fields ----------------------------------------------------------------------------------------------
const fields = block("fields");
if (fields) {
  check(fields.length >= 12, `the fields block lists the fields dockit reads (${fields.length})`);
  for (const line of fields) {
    const [path, ...flags] = line.split(/\s+/);
    const node = resolvePath(path);
    check(node !== undefined, `field ${path} exists in the structure schema`);
    if (node !== undefined && flags.includes("nullable")) check(isNullable(node), `field ${path} is nullable in the structure schema, as documented`);
  }
  for (const must of ["degraded", "structure.encrypted", "pages[].index", "pages[].text_layer", "pages[].text_layer.state", "pages[].text_layer.reliable", "pages[].script"]) {
    check(fields.some((l) => l.split(/\s+/)[0] === must), `the fields block documents ${must}`);
  }
}

// ---- states ----------------------------------------------------------------------------------------------
const states = block("states");
if (states) {
  const node = resolvePath("pages[].text_layer.state");
  const want = node ? enumValues(node) : new Set();
  check(want.size > 0, "the schema gives pages[].text_layer.state an enum");
  const have = new Set(states.map((l) => l.split(/\s+/)[0]));
  for (const s of have) check(want.has(s), `documented state ${s} is in the schema enum`);
  for (const s of want) check(have.has(s), `schema state ${s} is documented`);
}

// ---- limits ----------------------------------------------------------------------------------------------
const limits = block("limits");
if (limits) {
  const real = new Map();
  for (const m of limitsToml.matchAll(/^([a-z_]+)\s*=\s*(\d+)\s*$/gm)) real.set(m[1], m[2]);
  const seen = new Set();
  for (const line of limits) {
    const m = /^([a-z_]+)\s*=\s*(\d+)$/.exec(line);
    if (!m) { bad(`limits line is "key = integer": ${line}`); continue; }
    seen.add(m[1]);
    check(real.get(m[1]) === m[2], `limit ${m[1]} = ${m[2]} equals structural_limits.toml (${real.get(m[1])})`);
  }
  for (const must of ["max_input_bytes", "max_decompressed_bytes", "max_objects", "max_pages", "max_content_bytes_per_page", "max_content_bytes_total"]) {
    check(seen.has(must), `the limits block documents ${must}`);
  }
}

// ---- exports and build command ---------------------------------------------------------------------------
const exportsList = block("exports");
if (exportsList) {
  for (const name of exportsList.map((l) => l.split(/\s+/)[0])) {
    check(new RegExp(`pub fn ${name}\\(`).test(libRs), `exported function ${name} exists in crates/pagetriage-wasm/src/lib.rs`);
  }
  check(/#\[cfg\(feature = "pdf"\)\]\s*#\[wasm_bindgen\]\s*pub fn analyse_pdf_structure\(/.test(libRs), "analyse_pdf_structure is behind #[cfg(feature = \"pdf\")]");
}
const cmd = block("build");
if (cmd) {
  const line = cmd.find((l) => l.includes("build-wasm.sh")) || "";
  check(/PAGETRIAGE_WASM_FEATURES=pdf/.test(line) && /WASM_OUT=dist\/wasm\b/.test(line), "the documented build command sets PAGETRIAGE_WASM_FEATURES=pdf and WASM_OUT=dist/wasm");
  check(buildSh.includes("PAGETRIAGE_WASM_FEATURES") && buildSh.includes("WASM_OUT"), "scripts/build-wasm.sh reads both variables of the documented command");
}

// ---- benchmark numbers ----------------------------------------------------------------------------------
function parseCsv(text) {
  const rows = [];
  let row = [], cell = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') q = false; else cell += c; }
    else if (c === '"') q = true;
    else if (c === ",") { row.push(cell); cell = ""; }
    else if (c === "\n") { row.push(cell); rows.push(row); row = []; cell = ""; }
    else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  const head = rows.shift();
  return rows.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ""])));
}
const csvRows = parseCsv(csvText);
check(csvRows.length >= 14, `the benchmark CSV has its rows (${csvRows.length})`);
for (const [i, r] of csvRows.entries()) {
  const missing = ["machine", "browser", "commit", "build", "command", "kind", "subject"].filter((c) => !r[c]);
  check(missing.length === 0, `CSV row ${i + 2} (${r.subject}) names ${missing.length ? "no " + missing.join(", ") : "machine, browser, commit, build and command"}`);
  check(r.eight_gb_laptop === "not measured on 8 GB", `CSV row ${i + 2} (${r.subject}) says "not measured on 8 GB"`);
  check(/Apple M5 Pro 48 GB/.test(r.machine), `CSV row ${i + 2} names the machine as Apple M5 Pro 48 GB`);
}
const bomb = csvRows.find((r) => r.subject.startsWith("bomb"));
check(!!bomb, "the CSV has a decompression-bomb row");
if (bomb) {
  check(bomb.outcome === "ok" && Number(bomb.worst_ms) > 0 && Number(bomb.worst_ms) < 60000, `the bomb row returned in bounded time (worst ${bomb.worst_ms} ms < the 60000 ms worker timeout)`);
  check(/degraded=true/.test(bomb.detail) && /truncated_pages=1/.test(bomb.detail), "the bomb row is a degraded report with the page truncated");
}
const bench = block("bench");
if (bench) {
  const find = (k, s) => csvRows.find((r) => r.kind === k && (s === undefined || r.subject === s || r.subject.startsWith(s)));
  for (const line of bench) {
    const [name, a, b] = line.split(/\s+/);
    let row, want;
    if (name === "wasm_raw_bytes") { row = find("size", "pagetriage_bg.wasm raw"); want = [row && row.input_bytes]; }
    else if (name === "wasm_gzip9_bytes") { row = find("size", "pagetriage_bg.wasm gzip"); want = [row && row.input_bytes]; }
    else if (name === "init") { row = find("init"); want = [row && row.median_ms, row && row.worst_ms]; }
    else { row = find("analyse", name); want = [row && row.median_ms, row && row.worst_ms]; }
    const got = [a, b].slice(0, want.length);
    check(!!row && want.every((w, i) => w === got[i]), `doc number for ${name} (${got.join(" / ")}) equals the CSV (${want.join(" / ")})`);
  }
  for (const r of csvRows.filter((x) => x.kind === "analyse")) check(bench.some((l) => l.startsWith(r.subject + " ")), `the document quotes the CSV row ${r.subject}`);
}
process.stdout.write(out.join("\n") + "\n");
JS

RESULT=$(node "$CHECK" 2>&1) || { fail "wasm-api-doc check crashed: $RESULT"; finish; exit 1; }
while IFS= read -r line; do
  case "$line" in
    "ok   - "*) ok "${line#ok   - }" ;;
    "FAIL - "*) fail "${line#FAIL - }" ;;
    "") ;;
    *) fail "unexpected output: $line" ;;
  esac
done <<EOF
$RESULT
EOF
finish
