#!/usr/bin/env node
// Run the stream-accounting inputs through the WASM build that has the `pdf` feature (wasm-bindgen
// `nodejs` target) and require byte-identical reports. The inputs are the structure goldens
// (tests/golden/pdf) and the small synthetic bomb seeds (tests/golden/streams_inputs); the expected
// bytes are tests/golden/streams. Build first with
// `PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf scripts/build-wasm.sh`.
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const golden = join(here, "..", "golden");
const pkgDir = process.env.WASM_PKG ?? join(here, "..", "..", "dist", "wasm-pdf", "nodejs");
const wasm = createRequire(import.meta.url)(join(pkgDir, "pagetriage.js"));

const inputs = [];
for (const dir of ["pdf", "streams_inputs"]) {
  for (const f of readdirSync(join(golden, dir)).filter((f) => f.endsWith(".pdf"))) inputs.push([dir, f]);
}
inputs.sort((a, b) => (a[1] < b[1] ? -1 : 1));
if (inputs.length < 14) {
  console.error(`expected the 8 structure PDFs and at least 6 seeds, found ${inputs.length}`);
  process.exit(1);
}

let failures = 0;
for (const [dir, file] of inputs) {
  const name = file.replace(/\.pdf$/, "");
  const actual = wasm.account_pdf_streams(new Uint8Array(readFileSync(join(golden, dir, file))), undefined) + "\n";
  const expected = readFileSync(join(golden, "streams", `${name}.json`), "utf8");
  const digest = createHash("sha256").update(actual).digest("hex").slice(0, 16);
  if (actual === expected) {
    console.log(`ok   wasm   ${name.padEnd(24)} sha256=${digest}`);
  } else {
    failures++;
    let at = 0;
    while (at < actual.length && actual[at] === expected[at]) at++;
    console.log(`FAIL wasm   ${name}: first difference at byte ${at}`);
    console.log(`  actual  : ...${JSON.stringify(actual.slice(Math.max(0, at - 30), at + 40))}`);
    console.log(`  expected: ...${JSON.stringify(expected.slice(Math.max(0, at - 30), at + 40))}`);
  }
}

const notPdf = JSON.parse(wasm.account_pdf_streams(new TextEncoder().encode("definitely not a pdf"), undefined));
if (notPdf.verdict === "refuse" && notPdf.reason === "unaccounted") console.log("ok   wasm   non-PDF input is refused as unaccounted");
else {
  failures++;
  console.log(`FAIL wasm   non-PDF input gave ${notPdf.verdict} ${notPdf.reason}`);
}

const seed = new Uint8Array(readFileSync(join(golden, "streams_inputs", "seed_font_bomb.pdf")));
const raised = JSON.parse(wasm.account_pdf_streams(seed, JSON.stringify({ params: "font_decoded_max = 99999999999" })));
const lowered = JSON.parse(wasm.account_pdf_streams(seed, JSON.stringify({ params: "font_decoded_max = 1000" })));
if (raised.limits.font_decoded_max === 33554432 && lowered.limits.font_decoded_max === 1000) console.log("ok   wasm   options lower a limit and cannot raise one");
else {
  failures++;
  console.log(`FAIL wasm   limits ${raised.limits.font_decoded_max} / ${lowered.limits.font_decoded_max}`);
}

try {
  wasm.account_pdf_streams(seed, '{"nope": 1}');
  failures++;
  console.log("FAIL wasm   bad options did not throw");
} catch (e) {
  if (e instanceof Error) console.log("ok   wasm   bad options throw Error");
  else {
    failures++;
    console.log(`FAIL wasm   thrown value is not an Error: ${e}`);
  }
}

process.exit(failures ? 1 : 0);
