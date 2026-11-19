#!/usr/bin/env bash
# docs/detectors/streams.md documents the stream accounting (S1-107). This fails when the document names
# something the code no longer has, or quotes a number that is not in the committed measurements:
#
#   - the `streams:limits` block equals the seven echoed keys of crates/pagetriage-core/params/stream_limits.toml;
#   - the `streams:reasons` block equals the `reason` enum of schema/pagetriage-streams-0.1.schema.json, both ways;
#   - every name in the `streams:exports` block is a `pub fn` of crates/pagetriage-wasm/src/lib.rs and
#     account_pdf_streams sits behind #[cfg(feature = "pdf")];
#   - the `streams:residuals` block names the five things that stay reachable inside pdf.js;
#   - every row of docs/benchmarks/streams-native.csv and wasm-streams.csv names its machine, commit and command,
#     says "not measured on 8 GB", and is within its memory budget (input size + 64 MiB);
#   - every number in the `streams:bench` block equals the row of those two files it names.
#
# Each input can be pointed elsewhere (STREAMS_DOC, STREAMS_TOML, STREAMS_SCHEMA, WASM_LIB_RS, STREAMS_NATIVE_CSV,
# STREAMS_WASM_CSV) so that the drift test can run it against a doctored copy, which must fail.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

command -v node >/dev/null || { fail "node not found: streams-doc.sh cannot run (Node 22 is required)"; finish; exit 1; }
export DOC=${STREAMS_DOC:-$REPO/docs/detectors/streams.md}
export TOML=${STREAMS_TOML:-$REPO/crates/pagetriage-core/params/stream_limits.toml}
export SCHEMA=${STREAMS_SCHEMA:-$REPO/schema/pagetriage-streams-0.1.schema.json}
export LIBRS=${WASM_LIB_RS:-$REPO/crates/pagetriage-wasm/src/lib.rs}
export NATIVE_CSV=${STREAMS_NATIVE_CSV:-$REPO/docs/benchmarks/streams-native.csv}
export WASM_CSV=${STREAMS_WASM_CSV:-$REPO/docs/benchmarks/wasm-streams.csv}

expect_eq "docs/detectors/streams.md exists" yes "$([ -f "$DOC" ] && echo yes || echo no)"
if [ ! -f "$DOC" ]; then finish; exit 1; fi

CHECKDIR=$(mktemp -d)
CHECK=$CHECKDIR/check.mjs
trap 'rm -rf "$CHECKDIR"' EXIT
cat > "$CHECK" <<'JS'
import { readFileSync } from "node:fs";
const doc = readFileSync(process.env.DOC, "utf8");
const toml = readFileSync(process.env.TOML, "utf8");
const schema = JSON.parse(readFileSync(process.env.SCHEMA, "utf8"));
const libRs = readFileSync(process.env.LIBRS, "utf8");
const out = [];
const ok = (m) => out.push(`ok   - ${m}`);
const bad = (m) => out.push(`FAIL - ${m}`);
const check = (cond, m) => (cond ? ok(m) : bad(m));

function block(name) {
  const m = new RegExp(`<!-- streams:${name}:start -->\\s*\`\`\`[a-z]*\\n([\\s\\S]*?)\`\`\`\\s*<!-- streams:${name}:end -->`).exec(doc);
  if (!m) { bad(`block streams:${name} is present in the document`); return null; }
  return m[1].split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
}

// RFC 4180-ish CSV with quoted fields
function parseCsv(path) {
  const text = readFileSync(path, "utf8");
  const rows = [];
  for (const line of text.split("\n")) {
    if (!line) continue;
    const cells = [];
    let cur = "", q = false;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (q) { if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; } else if (c === '"') q = false; else cur += c; }
      else if (c === '"') q = true;
      else if (c === ",") { cells.push(cur); cur = ""; }
      else cur += c;
    }
    cells.push(cur);
    rows.push(cells);
  }
  const [header, ...body] = rows;
  return body.map((r) => Object.fromEntries(header.map((h, i) => [h, r[i]])));
}

// ---- limits ----------------------------------------------------------------------------------------------
const echoed = ["font_decoded_max", "image_decoded_max", "image_raster_max", "content_decoded_max", "other_decoded_max", "total_decoded_max", "streams_max"];
const real = new Map();
for (const m of toml.matchAll(/^([a-z_]+)\s*=\s*(\d+)\s*$/gm)) real.set(m[1], m[2]);
const limits = block("limits");
if (limits) {
  const seen = new Set();
  for (const line of limits) {
    const m = /^([a-z_]+)\s*=\s*(\d+)$/.exec(line);
    if (!m) { bad(`limits line is "key = integer": ${line}`); continue; }
    seen.add(m[1]);
    check(real.get(m[1]) === m[2], `limit ${m[1]} = ${m[2]} equals stream_limits.toml (${real.get(m[1])})`);
  }
  for (const k of echoed) check(seen.has(k), `the limits block documents ${k}`);
}

// ---- reasons ---------------------------------------------------------------------------------------------
const reasons = block("reasons");
if (reasons) {
  const want = new Set();
  const node = schema.$defs?.StreamsReason;
  for (const v of node?.oneOf ?? []) { for (const e of v.enum ?? []) want.add(e); if (typeof v.const === "string") want.add(v.const); }
  want.delete("");
  check(want.size === 7, `the schema gives the reason 7 non-empty values (${want.size})`);
  const have = new Set(reasons.map((l) => l.split(/\s+/)[0]));
  for (const r of have) check(want.has(r), `documented reason ${r} is in the schema enum`);
  for (const r of want) check(have.has(r), `schema reason ${r} is documented`);
}

// ---- exports ---------------------------------------------------------------------------------------------
const exports = block("exports");
if (exports) {
  for (const line of exports) {
    const name = line.split(/\s+/)[0];
    check(new RegExp(`pub fn ${name}\\b`).test(libRs), `export ${name} is a pub fn in the WASM crate`);
  }
  check(/#\[cfg\(feature = "pdf"\)\]\s*#\[wasm_bindgen\]\s*pub fn account_pdf_streams/.test(libRs), "account_pdf_streams sits behind #[cfg(feature = \"pdf\")]");
}

// ---- residuals -------------------------------------------------------------------------------------------
const residuals = block("residuals");
if (residuals) {
  const text = residuals.join("\n").toLowerCase();
  for (const [kw, what] of [["inline image", "inline images (BI/ID/EI) with filters"], ["type 3", "Type 3 glyph procedures"], ["shading", "shading and function streams"], ["cpu", "font-parsing CPU cost"], ["reconstruction", "xref reconstruction differences"]]) {
    check(text.includes(kw), `the residuals block names ${what}`);
  }
}

// ---- measurements ----------------------------------------------------------------------------------------
const native = parseCsv(process.env.NATIVE_CSV);
const wasm = parseCsv(process.env.WASM_CSV);
check(native.length >= 12, `streams-native.csv has the bombs (${native.length} rows)`);
check(wasm.length >= 12, `wasm-streams.csv has the bombs (${wasm.length} rows)`);
for (const [label, rows] of [["streams-native.csv", native], ["wasm-streams.csv", wasm]]) {
  for (const r of rows) {
    const where = `${label} ${r.file}`;
    check(r.machine && r.commit && r.command, `${where} names its machine, commit and command`);
    check(r.eight_gb_laptop === "not measured on 8 GB", `${where} says "not measured on 8 GB"`);
    check(r.within_budget === "true", `${where} is within input + 64 MiB`);
    check(Number(r.budget_bytes) === Number(r.input_bytes) + 64 * 1024 * 1024, `${where} states its budget as input + 64 MiB`);
  }
}
const bench = block("bench");
if (bench) {
  check(bench.length >= 8, `the bench block quotes the bombs (${bench.length} lines)`);
  for (const line of bench) {
    // file reason native_peak_rss_bytes wasm_memory_after_bytes
    const [file, reason, peak, mem] = line.split(/\s+/);
    const n = native.find((r) => r.file === file);
    const w = wasm.find((r) => r.file === file);
    check(n !== undefined && w !== undefined, `${file} is in both CSV files`);
    if (!n || !w) continue;
    check((n.reason || "-") === reason && (w.reason || "-") === reason, `${file}: reason ${reason} equals both CSV files`);
    check(n.peak_rss_bytes === peak, `${file}: native peak ${peak} equals streams-native.csv (${n.peak_rss_bytes})`);
    check(w.wasm_memory_after_bytes === mem, `${file}: WASM memory ${mem} equals wasm-streams.csv (${w.wasm_memory_after_bytes})`);
  }
}
console.log(out.join("\n"));
JS
node "$CHECK" > "$CHECKDIR/out.txt" 2>"$CHECKDIR/err.txt" || { cat "$CHECKDIR/err.txt"; fail "streams-doc check script crashed"; }
while IFS= read -r line; do
  case "$line" in
    "ok   - "*) ok "${line#ok   - }" ;;
    "FAIL - "*) fail "${line#FAIL - }" ;;
  esac
done < "$CHECKDIR/out.txt"
finish
