#!/usr/bin/env node
// Stream accounting in installed Chrome (S1-107): for each synthetic bomb, run the PDF-enabled WASM
// build 5 times and log the WebAssembly memory (memory.buffer.byteLength) before and after, the wall
// time of each run, and the verdict, against the budget "memory after <= input size + 64 MiB".
//
//   node bench/streams_wasm_chrome.mjs <bombs-dir> [runs] [--csv <file>]
//
// <bombs-dir> holds the files written by `examples/gen_stream_bombs.rs` (see scripts/stream-bombs.sh;
// nothing in it is ever committed). The package is dist/wasm-pdf/web, built by
// `PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf scripts/build-wasm.sh`; WASM_WEB overrides it.
// Playwright drives the installed Chrome (channel "chrome", no browser download). The repository has no
// Node dependencies of its own: point PLAYWRIGHT_MODULE at an installed `playwright` folder, or install
// it where Node can find it (`npm i --no-save playwright`).
//
// Output: one JSON line per file on stdout, then a table on stderr. The figures are for this machine
// (not an 8 GB laptop): not measured on 8 GB.
import http from "node:http";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import os from "node:os";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..");
const args = process.argv.slice(2);
const csvAt = args.indexOf("--csv");
const csvPath = csvAt >= 0 ? args.splice(csvAt, 2)[1] : null;
const bombs = args[0];
const runs = Number(args[1] ?? 5);
if (!bombs) {
  console.error("usage: node bench/streams_wasm_chrome.mjs <bombs-dir> [runs]");
  process.exit(2);
}
const webDir = process.env.WASM_WEB ?? join(repo, "dist", "wasm-pdf", "web");
let playwright;
try {
  playwright = process.env.PLAYWRIGHT_MODULE
    ? createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE)
    : await import("playwright");
} catch (e) {
  console.error(`cannot load playwright: ${e.message}\nset PLAYWRIGHT_MODULE to an installed playwright folder, or npm i --no-save playwright`);
  process.exit(2);
}
const { chromium } = playwright.chromium ? playwright : playwright.default;

const page = `<!doctype html><meta charset="utf-8"><title>streams</title><script type="module">
import init, { account_pdf_streams } from "/pkg/pagetriage.js";
const wasm = await init({ module_or_path: "/pkg/pagetriage_bg.wasm" });
window.__ready = true;
window.__measure = async (name, runs) => {
  const bytes = new Uint8Array(await (await fetch("/bombs/" + name)).arrayBuffer());
  const out = { name, inputBytes: bytes.length, memoryBefore: wasm.memory.buffer.byteLength, runs: [] };
  for (let i = 0; i < runs; i++) {
    const t0 = performance.now();
    let verdict, reason;
    try {
      const r = JSON.parse(account_pdf_streams(bytes, undefined));
      verdict = r.verdict; reason = r.reason;
    } catch (e) { verdict = "threw"; reason = String(e && e.message || e).slice(0, 80); }
    out.runs.push({ ms: Math.round((performance.now() - t0) * 10) / 10, memoryAfter: wasm.memory.buffer.byteLength, verdict, reason });
  }
  return out;
};
</script>`;

const mime = { ".js": "text/javascript", ".wasm": "application/wasm", ".html": "text/html" };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  let file = null;
  if (url.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(page);
    return;
  }
  if (url.pathname.startsWith("/pkg/")) file = join(webDir, basename(url.pathname));
  else if (url.pathname.startsWith("/bombs/")) file = join(bombs, basename(url.pathname));
  try {
    const data = readFileSync(file);
    const ext = file.slice(file.lastIndexOf("."));
    res.writeHead(200, { "content-type": mime[ext] ?? "application/octet-stream" });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const browser = await chromium.launch({ channel: "chrome", headless: true });
const results = [];
try {
  const errors = [];
  const version = browser.version();
  const files = readdirSync(bombs).filter((f) => f.endsWith(".pdf")).sort();
  for (const f of files) {
    // A page of its own for every file: a WebAssembly memory never shrinks, so one shared instance would
    // carry the growth of an earlier file into the figure of a later one.
    const pg = await browser.newPage();
    pg.on("pageerror", (e) => errors.push(String(e)));
    pg.on("console", (m) => m.type() === "error" && !/favicon|404/.test(m.text()) && errors.push(m.text()));
    await pg.goto(`http://127.0.0.1:${port}/`);
    await pg.waitForFunction("window.__ready === true", null, { timeout: 60000 });
    const r = await pg.evaluate(([n, k]) => window.__measure(n, k), [f, runs]);
    await pg.close();
    const worst = Math.max(...r.runs.map((x) => x.memoryAfter));
    const ms = r.runs.map((x) => x.ms).sort((a, b) => a - b);
    const row = {
      file: f,
      input_bytes: r.inputBytes,
      verdict: r.runs[0].verdict,
      reason: r.runs[0].reason,
      runs,
      wasm_memory_before_bytes: r.memoryBefore,
      wasm_memory_after_bytes_max: worst,
      budget_bytes: r.inputBytes + 64 * 1024 * 1024,
      within_budget: worst <= r.inputBytes + 64 * 1024 * 1024,
      ms_min: ms[0],
      ms_median: ms[Math.floor(ms.length / 2)],
      ms_max: ms[ms.length - 1],
      chrome: version,
      machine: `${os.cpus()[0].model}, ${os.cpus().length} cores, ${os.platform()} ${os.arch()}, ${Math.round(os.totalmem() / 2 ** 30)} GiB`,
      eight_gb: "not measured on 8 GB",
    };
    results.push(row);
    console.log(JSON.stringify(row));
  }
  if (errors.length) {
    console.error("page errors:", errors);
    process.exitCode = 1;
  }
} finally {
  await browser.close();
  server.close();
}
if (csvPath) {
  const q = (v) => `"${String(v).replace(/"/g, '""')}"`;
  let commit = "unknown";
  try {
    const { execFileSync } = await import("node:child_process");
    commit = execFileSync("git", ["rev-parse", "--short=12", "HEAD"], { cwd: repo }).toString().trim();
    if (execFileSync("git", ["status", "--porcelain"], { cwd: repo }).toString().trim()) commit += "-dirty";
  } catch { /* not a git checkout */ }
  const { createHash } = await import("node:crypto");
  const build = createHash("sha256").update(readFileSync(join(webDir, "pagetriage_bg.wasm"))).digest("hex").slice(0, 12);
  const header = "machine,browser,commit,build,command,file,input_bytes,verdict,reason,runs,median_ms,worst_ms,wasm_memory_before_bytes,wasm_memory_after_bytes,budget_bytes,within_budget,eight_gb_laptop";
  const lines = results.map((r) =>
    [
      q(r.machine),
      q(`Chrome ${r.chrome}`),
      commit,
      build,
      q("PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf bash scripts/build-wasm.sh && node bench/streams_wasm_chrome.mjs BOMBS_DIR 5 --csv docs/benchmarks/wasm-streams.csv"),
      r.file,
      r.input_bytes,
      r.verdict,
      r.reason,
      r.runs,
      r.ms_median,
      r.ms_max,
      r.wasm_memory_before_bytes,
      r.wasm_memory_after_bytes_max,
      r.budget_bytes,
      r.within_budget,
      r.eight_gb,
    ].join(","),
  );
  writeFileSync(csvPath, [header, ...lines].join("\n") + "\n");
}
console.error(["file", "input", "verdict/reason", "mem before", "mem after (max)", "within input+64MiB", "ms min/med/max"].join("\t"));
for (const r of results) {
  console.error([r.file, r.input_bytes, `${r.verdict}/${r.reason || "-"}`, r.wasm_memory_before_bytes, r.wasm_memory_after_bytes_max, r.within_budget, `${r.ms_min}/${r.ms_median}/${r.ms_max}`].join("\t"));
}
process.exit(results.every((r) => r.within_budget) && !process.exitCode ? 0 : 1);
