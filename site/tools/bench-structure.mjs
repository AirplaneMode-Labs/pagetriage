#!/usr/bin/env node
// Measures the call dockit makes, `analyse_pdf_structure`, in installed Chrome, inside a module Web Worker (as
// dockit's analysis worker will run it), and writes docs/benchmarks/wasm-structure.csv. Not run in CI (Playwright is
// not a dependency of this repository; Chrome is the installed one, channel "chrome", no browser download).
//
//   PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm bash scripts/build-wasm.sh
//   PLAYWRIGHT_MODULE=/path/to/node_modules/playwright \
//     node site/tools/bench-structure.mjs --wasm dist/wasm/web --out docs/benchmarks/wasm-structure.csv
//   node site/tools/bench-structure.mjs --wasm dist/wasm/web --csp-check      (CSP behaviour only, no CSV)
//
// Rows: the raw and gzip -9 size of pagetriage_bg.wasm; the time to start a fresh worker and instantiate the WASM;
// and, per input, the time of one analyse_pdf_structure call (5 runs in one worker, median and worst, the first
// run being the cold one). Inputs: every PDF in site/samples/pdf, generated 20- and 100-page text PDFs (synthetic,
// seeded, no real text) and a generated decompression bomb (a content stream that inflates to 1.07 GiB from about
// 1 MiB). Everything here is measured on the machine named in the machine column; nothing is measured on 8 GB.
//
// Node 22, node: modules only (plus Playwright, resolved at run time). The fixtures are never written to disk.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { arch, cpus, release, totalmem } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createDeflate, gzipSync } from "node:zlib";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");

// ---------------------------------------------------------------------------------------------------------
// arguments
// ---------------------------------------------------------------------------------------------------------
const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : dflt;
};
const WASM_DIR = resolve(REPO, opt("--wasm", "dist/wasm/web"));
const OUT = opt("--out", "");
const RUNS = Number(opt("--runs", "5"));
const TIMEOUT_MS = Number(opt("--timeout-ms", "60000")); // dockit's pdf-worker timeout
const CSP_CHECK = args.includes("--csp-check");
if (!Number.isInteger(RUNS) || RUNS < 1) throw new Error("--runs must be a positive integer");

function loadPlaywright() {
  const req = createRequire(import.meta.url);
  for (const spec of [process.env.PLAYWRIGHT_MODULE, "playwright"].filter(Boolean)) {
    try { return req(spec); } catch { /* try the next */ }
  }
  throw new Error("playwright not found: set PLAYWRIGHT_MODULE to the path of an installed playwright package (npm i playwright@1.65.0 in a scratch directory)");
}

// ---------------------------------------------------------------------------------------------------------
// synthetic fixtures
// ---------------------------------------------------------------------------------------------------------
function pdfFile(bodies) {
  const parts = [Buffer.from("%PDF-1.4\n%âãÏÓ\n", "latin1")];
  const offsets = [];
  let pos = parts[0].length;
  bodies.forEach((body, i) => {
    offsets.push(pos);
    const chunk = Buffer.concat([Buffer.from(`${i + 1} 0 obj\n`, "latin1"), Buffer.isBuffer(body) ? body : Buffer.from(body, "latin1"), Buffer.from("\nendobj\n", "latin1")]);
    parts.push(chunk);
    pos += chunk.length;
  });
  let xref = `xref\n0 ${bodies.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets) xref += `${String(o).padStart(10, "0")} 00000 n \n`;
  xref += `trailer\n<< /Size ${bodies.length + 1} /Root 1 0 R >>\nstartxref\n${pos}\n%%EOF\n`;
  parts.push(Buffer.from(xref, "latin1"));
  return Buffer.concat(parts);
}
const streamObj = (dict, data) => Buffer.concat([Buffer.from(`<< ${dict} /Length ${data.length} >>\nstream\n`, "latin1"), data, Buffer.from("\nendstream", "latin1")]);

// A small seeded generator (mulberry32), so the same fixture comes out on every run and every machine.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const WORDS = "the of and to in is that for it as was with be by on not he this are or his from at which but have an had they you were their one all we can her has there been if more when will would who so no".split(" ");
function textPdf(pages, seed) {
  const rand = rng(seed);
  const bodies = ["<< /Type /Catalog /Pages 2 0 R >>", `<< /Type /Pages /Kids [${Array.from({ length: pages }, (_, i) => `${4 + i * 2} 0 R`).join(" ")}] /Count ${pages} >>`, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"];
  for (let p = 0; p < pages; p++) {
    let content = "BT /F1 10 Tf 72 750 Td 12 TL\n";
    for (let l = 0; l < 52; l++) {
      let line = "";
      while (line.length < 88) line += WORDS[Math.floor(rand() * WORDS.length)] + " ";
      content += `(${line.trim()}) Tj T*\n`;
    }
    content += "ET\n";
    bodies.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + p * 2} 0 R >>`);
    bodies.push(streamObj("", Buffer.from(content, "latin1")));
  }
  return pdfFile(bodies);
}
// One page whose only content stream is Flate data that inflates to `total` zero bytes.
async function bombPdf(total) {
  const d = createDeflate({ level: 9 });
  const chunks = [];
  d.on("data", (c) => chunks.push(c));
  const zero = Buffer.alloc(1 << 20);
  for (let i = 0; i < total / zero.length; i++) if (!d.write(zero)) await once(d, "drain");
  d.end();
  await once(d, "end");
  const data = Buffer.concat(chunks);
  const file = pdfFile(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents 4 0 R >>", streamObj("/Filter /FlateDecode", data)]);
  return { file, inflated: (total / zero.length) * zero.length };
}

// ---------------------------------------------------------------------------------------------------------
// the page and the worker (served from a loopback server; the WASM package comes from --wasm)
// ---------------------------------------------------------------------------------------------------------
const WORKER_JS = `
import init, { analyse_pdf_structure, version } from "/pkg/pagetriage.js";
let wasm;
self.onmessage = async (e) => {
  const m = e.data;
  if (m.type === "init") {
    const t0 = performance.now();
    try {
      wasm = await init({ module_or_path: "/pkg/pagetriage_bg.wasm" });
      self.postMessage({ type: "ready", ms: performance.now() - t0, version: version(), memory: wasm.memory.buffer.byteLength });
    } catch (err) {
      self.postMessage({ type: "ready", error: String((err && err.message) || err) });
    }
  } else if (m.type === "run") {
    const bytes = new Uint8Array(m.buf);
    const t0 = performance.now();
    let msg;
    try {
      const json = analyse_pdf_structure(bytes, undefined);
      const ms = performance.now() - t0;
      const rep = JSON.parse(json);
      msg = { ok: true, ms, jsonBytes: json.length, pages: rep.pages.length, degraded: rep.degraded, encrypted: rep.structure.encrypted, nullLayers: rep.pages.filter((p) => p.text_layer === null).length, truncatedPages: rep.pages.filter((p) => p.features && p.features.truncated).length, states: rep.structure.page_states };
    } catch (err) {
      msg = { ok: false, ms: performance.now() - t0, error: String((err && err.message) || err) };
    }
    msg.type = "done";
    msg.memory = wasm.memory.buffer.byteLength;
    self.postMessage(msg);
  }
};
`;
const PAGE_JS = `
const once = (w, type, ms) => new Promise((res) => {
  const t = setTimeout(() => res({ timeout: true }), ms);
  const h = (e) => { if (e.data.type === type) { clearTimeout(t); w.removeEventListener("message", h); res(e.data); } };
  w.addEventListener("message", h);
});
window.spawn = async (ms) => {
  const w = new Worker("/worker.js", { type: "module" });
  window.__w = window.__w || [];
  const wait = once(w, "ready", ms);
  w.postMessage({ type: "init" });
  const r = await wait;
  if (r.timeout || r.error) { w.terminate(); return r; }
  const id = window.__w.push(w) - 1;
  return { ...r, id };
};
window.call = async (id, name, ms) => {
  const w = window.__w[id];
  const buf = await (await fetch("/fx/" + name)).arrayBuffer();
  const wait = once(w, "done", ms);
  w.postMessage({ type: "run", buf }, [buf]);
  const r = await wait;
  if (r.timeout) { w.terminate(); window.__w[id] = null; }
  return r;
};
window.kill = (id) => { if (window.__w[id]) window.__w[id].terminate(); window.__w[id] = null; };
window.ready = true;
`;
const PAGE_HTML = `<!doctype html><meta charset="utf-8"><title>bench</title><script type="module" src="/page.js"></script>`;

function serve(files, csp) {
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://x").pathname;
    const send = (type, body) => {
      const h = { "content-type": type, "cache-control": "no-store" };
      if (csp) h["content-security-policy"] = csp;
      res.writeHead(200, h);
      res.end(body);
    };
    if (url === "/") return send("text/html; charset=utf-8", PAGE_HTML);
    if (url === "/favicon.ico") { res.writeHead(204); return res.end(); }
    if (url === "/page.js") return send("text/javascript", PAGE_JS);
    if (url === "/worker.js") return send("text/javascript", WORKER_JS);
    if (url === "/pkg/pagetriage.js") return send("text/javascript", readFileSync(join(WASM_DIR, "pagetriage.js")));
    if (url === "/pkg/pagetriage_bg.wasm") return send("application/wasm", readFileSync(join(WASM_DIR, "pagetriage_bg.wasm")));
    if (url.startsWith("/fx/") && files.has(decodeURIComponent(url.slice(4)))) return send("application/pdf", files.get(decodeURIComponent(url.slice(4))));
    res.writeHead(404);
    res.end("not found");
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok(server)));
}

// ---------------------------------------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------------------------------------
const median = (xs) => { const s = [...xs].sort((a, b) => a - b); const n = s.length; return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2; };
const fix = (x) => (Number.isFinite(x) ? x.toFixed(2) : "");
const csv = (v) => { const s = String(v ?? ""); return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
function git(...a) { try { return execFileSync("git", ["-C", REPO, ...a], { encoding: "utf8" }).trim(); } catch { return ""; } }
function machine() {
  let brand = "";
  try { brand = execFileSync("sysctl", ["-n", "machdep.cpu.brand_string"], { encoding: "utf8" }).trim(); } catch { brand = cpus()[0]?.model ?? "unknown CPU"; }
  return `${brand} ${Math.round(totalmem() / 2 ** 30)} GB (${process.platform} ${release()} ${arch()}, ${cpus().length} cores)`;
}

// ---------------------------------------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------------------------------------
const { chromium } = loadPlaywright();

async function cspCheck() {
  const browser = await chromium.launch({ channel: "chrome", headless: true });
  console.log(`Chrome ${browser.version()}`);
  for (const [label, csp] of [
    ["script-src 'self'  (no wasm-unsafe-eval)", "default-src 'none'; script-src 'self'; worker-src 'self'; connect-src 'self'"],
    ["script-src 'self' 'wasm-unsafe-eval'", "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'"],
  ]) {
    const server = await serve(new Map(), csp);
    const page = await (await browser.newContext()).newPage();
    const msgs = [];
    page.on("console", (m) => msgs.push(m.text()));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForFunction(() => window.ready === true, null, { timeout: 15000 });
    const r = await page.evaluate(() => window.spawn(15000));
    console.log(`${label}\n  worker + instantiate: ${r.error ? "REFUSED: " + r.error.slice(0, 160) : r.timeout ? "TIMEOUT" : "ok " + r.ms.toFixed(1) + " ms, version " + r.version}`);
    await page.context().close();
    server.close();
  }
  await browser.close();
}

if (CSP_CHECK) {
  await cspCheck();
  process.exit(0);
}
if (!OUT) throw new Error("--out <csv> is required (or --csp-check)");

const wasmBytes = readFileSync(join(WASM_DIR, "pagetriage_bg.wasm"));
const wasmSha = createHash("sha256").update(wasmBytes).digest("hex").slice(0, 12);
const files = new Map();
const pdfDir = join(REPO, "site", "samples", "pdf");
for (const f of readdirSync(pdfDir).filter((n) => n.endsWith(".pdf")).sort()) files.set(`sample-${f}`, readFileSync(join(pdfDir, f)));
files.set("text-20p.pdf", textPdf(20, 20));
files.set("text-100p.pdf", textPdf(100, 100));
files.set("text-300p.pdf", textPdf(300, 300)); // 300 pages is the page cap dockit applies before calling the library
process.stderr.write("generating the decompression bomb ...\n");
const bomb = await bombPdf(1100 * (1 << 20));
files.set("bomb-content-1p.pdf", bomb.file);

const server = await serve(files);
const browser = await chromium.launch({ channel: "chrome", headless: true });
const chrome = `Chrome ${browser.version()}`;
const page = await (await browser.newContext()).newPage();
const consoleErrors = [];
page.on("console", (m) => { if (m.type() === "error") consoleErrors.push(m.text()); });
page.on("pageerror", (e) => consoleErrors.push(String(e)));
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await page.waitForFunction(() => window.ready === true, null, { timeout: 15000 });

const cmd = `PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm bash scripts/build-wasm.sh && node site/tools/bench-structure.mjs --wasm ${opt("--wasm", "dist/wasm/web")} --out ${OUT} --runs ${RUNS}`;
const dirty = git("status", "--porcelain", "--", "crates", "Cargo.toml", "Cargo.lock", "scripts/build-wasm.sh").length > 0;
const commit = `${git("rev-parse", "--short=12", "HEAD")}${dirty ? "-dirty" : ""}`;
const base = { machine: machine(), browser: chrome, commit, build: wasmSha, command: cmd };
const rows = [];
const add = (r) => rows.push({ ...base, input_bytes: "", pages: "", runs: "", median_ms: "", worst_ms: "", outcome: "ok", detail: "", wasm_memory_bytes: "", eight_gb_laptop: "not measured on 8 GB", ...r });

add({ kind: "size", subject: "pagetriage_bg.wasm raw", input_bytes: wasmBytes.length });
// The same measure as scripts/check-wasm-size.sh (the gzip CLI at -9); node's zlib level 9 gives a different, larger count.
let gz;
try {
  gz = { label: "pagetriage_bg.wasm gzip -9 (gzip CLI, as scripts/check-wasm-size.sh)", n: execFileSync("gzip", ["-9", "-c", join(WASM_DIR, "pagetriage_bg.wasm")], { maxBuffer: 1 << 26 }).length };
} catch {
  gz = { label: "pagetriage_bg.wasm gzip level 9 (node zlib; the gzip CLI is not available, so this is not the check-wasm-size.sh figure)", n: gzipSync(wasmBytes, { level: 9 }).length };
}
add({ kind: "size", subject: gz.label, input_bytes: gz.n });

// worker start + WASM instantiate, fresh each time
{
  const ms = [];
  let memory = 0;
  for (let i = 0; i < RUNS; i++) {
    const r = await page.evaluate((t) => window.spawn(t), TIMEOUT_MS);
    if (r.error || r.timeout) throw new Error(`worker start failed: ${r.error ?? "timeout"}`);
    ms.push(r.ms);
    memory = r.memory;
    await page.evaluate((id) => window.kill(id), r.id);
  }
  add({ kind: "init", subject: "fresh worker: fetch + compile + instantiate", runs: RUNS, median_ms: fix(median(ms)), worst_ms: fix(Math.max(...ms)), detail: "performance.now in the worker, from the init message to ready", wasm_memory_bytes: memory });
}

for (const [name, bytes] of files) {
  const init = await page.evaluate((t) => window.spawn(t), TIMEOUT_MS);
  if (init.error || init.timeout) throw new Error(`worker start failed: ${init.error ?? "timeout"}`);
  const ms = [];
  let last = null;
  let timedOut = false;
  for (let i = 0; i < RUNS; i++) {
    const t0 = Date.now();
    const r = await page.evaluate(([id, n, t]) => window.call(id, n, t), [init.id, name, TIMEOUT_MS]);
    if (r.timeout) { timedOut = true; ms.push(Date.now() - t0); break; }
    ms.push(r.ms);
    last = r;
  }
  if (!timedOut) await page.evaluate((id) => window.kill(id), init.id);
  const detail = last && last.ok ? `pages=${last.pages}; degraded=${last.degraded}; encrypted=${last.encrypted}; text_layer_null_pages=${last.nullLayers}; truncated_pages=${last.truncatedPages}; json_bytes=${last.jsonBytes}; states=${JSON.stringify(last.states)}` : "";
  let outcome = "ok";
  if (timedOut) outcome = `timeout after ${TIMEOUT_MS} ms (worker terminated)`;
  else if (last && !last.ok) outcome = `error: ${String(last.error).slice(0, 120)}`;
  const inflated = name.startsWith("bomb") ? `; the content stream inflates to ${bomb.inflated} bytes unbounded` : "";
  add({ kind: "analyse", subject: name, input_bytes: bytes.length, pages: last && last.ok ? last.pages : "", runs: ms.length, median_ms: fix(median(ms)), worst_ms: fix(Math.max(...ms)), outcome, detail: detail + inflated, wasm_memory_bytes: last ? last.memory : "" });
}
await browser.close();
server.close();

const cols = ["machine", "browser", "commit", "build", "command", "kind", "subject", "input_bytes", "pages", "runs", "median_ms", "worst_ms", "outcome", "detail", "wasm_memory_bytes", "eight_gb_laptop"];
writeFileSync(resolve(REPO, OUT), [cols.join(","), ...rows.map((r) => cols.map((c) => csv(r[c])).join(","))].join("\n") + "\n");
if (consoleErrors.length) console.log("console errors on the bench page:", consoleErrors);
for (const r of rows) console.log(`${r.kind.padEnd(8)} ${String(r.subject).padEnd(44)} in=${String(r.input_bytes).padStart(9)} median=${String(r.median_ms).padStart(9)} worst=${String(r.worst_ms).padStart(9)} ${r.outcome}`);
console.log(`wrote ${OUT} (${rows.length} rows, ${chrome}, ${commit})`);
