// The demo at its Pages sub-path, in installed Chrome (Sprint 6): serves site/ under /<repo>/ with a server that 404s every
// other path, opens the page, and for each PDF sample reads what the page shows. Checks, for the PDF samples and the three
// refused seeds: the stream check shows a verdict and a table of counts as text; a seed over a limit is refused with the
// plain sentence and no page report (the structure analysis was not run); the others show the page report as before; the
// sprint status line is the one in --status-line; there is a "does not do yet" box; there are 0 console errors and every
// request is same-origin.
//
//   node site/tools/browser-check-streams.mjs [--status-line <file>] [--base /pagetriage/]
//
// Needs the built site (scripts/build-site.sh). Playwright is not a dependency of this repository: point
// PLAYWRIGHT_MODULE at an installed `playwright` folder. It drives the installed Chrome (channel "chrome"; no download).
import http from "node:http";
import { readFileSync, existsSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const site = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const opt = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const base = opt("--base", "/pagetriage/");
const statusLineFile = opt("--status-line", null);
const playwright = createRequire(import.meta.url)(process.env.PLAYWRIGHT_MODULE ?? "playwright");

const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".json": "application/json", ".wasm": "application/wasm", ".png": "image/png", ".pdf": "application/pdf", ".txt": "text/plain", ".svg": "image/svg+xml" };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  if (!url.pathname.startsWith(base)) { res.writeHead(404); res.end(); return; }
  let rel = decodeURIComponent(url.pathname.slice(base.length)) || "index.html";
  if (rel.endsWith("/")) rel += "index.html";
  const file = join(site, rel);
  if (!file.startsWith(site) || rel.startsWith("tools/") || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream" });
  res.end(readFileSync(file));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = `http://127.0.0.1:${server.address().port}`;

let failures = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failures++; };

const browser = await playwright.chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage();
const consoleErrors = [];
const foreign = new Set();
page.on("console", (m) => m.type() === "error" && consoleErrors.push(m.text()));
page.on("pageerror", (e) => consoleErrors.push(String(e)));
page.on("request", (r) => { if (!r.url().startsWith(origin) && !r.url().startsWith("data:") && !r.url().startsWith("blob:")) foreign.add(r.url()); });
try {
  await page.goto(`${origin}${base}`);
  await page.waitForSelector("#picker button");
  check(/^Sprint 6 \(19 Nov 2026\): Working: /.test(await page.textContent("#sprint-status")) && (await page.textContent("#sprint-status")).includes(" Not yet: "), "the status line starts 'Sprint 6 (19 Nov 2026): Working: ... Not yet: ...'");
  if (statusLineFile) check((await page.textContent("#sprint-status")).trim() === readFileSync(statusLineFile, "utf8").trim(), `the status line equals ${statusLineFile}`);
  check((await page.locator("#not-yet li").count()) >= 6, "the 'does not do yet' box is there with its list");
  const notYet = await page.textContent("#not-yet");
  check(/OCR/.test(notYet) && /not measured on 8 GB/.test(notYet) && /signed release/i.test(notYet) && /No published package, and no tag/.test(notYet), "the not-yet box names OCR, the 8 GB gap, a signed release, a tag and a published package");
  await page.click("#tab-pdf");
  await page.waitForSelector("#pdflist button");
  const buttons = await page.$$eval("#pdflist button", (bs) => bs.map((b) => [b.dataset.id, b.querySelector("strong").textContent]));
  const ids = buttons.map((b) => b[0]);
  check(ids.length === 11, `the PDF list has 8 samples and 3 refused seeds (${ids.length})`);

  const slip = async () => (await page.textContent("#slip-body")) ?? "";
  for (const id of ids) {
    await page.click(`#pdflist button[data-id="${id}"]`);
    // the slip still shows the previous sample until this one's result arrives: wait for this sample's title and its stream box
    const title = buttons.find((b) => b[0] === id)[1];
    await page.waitForFunction((t) => { const b = document.querySelector("#slip-body"); return b && b.textContent.includes(t) && b.querySelector("section.streams"); }, title, { timeout: 60000 });
    const text = await slip();
    const seed = id.startsWith("seed_");
    const rows = await page.locator("#slip-body section.streams tbody tr").count();
    check(rows === 5, `${id}: the stream table has its 5 kinds (${rows})`);
    check(/Streams by kind/.test(text) && /checked in \d+ ms on your device/.test(text), `${id}: counts and timing are shown as text`);
    if (id === "seed_font_bomb") {
      check(/Refused: A font in this file decodes to more than 32 MiB\./.test(text), `${id}: refused with the plain font sentence`);
      check(/This PDF was refused before it was opened\./.test(text) && !(await page.locator("#slip-body table.pages caption", { hasText: "Page by page" }).count()), `${id}: no page report (not opened)`);
      check(/at least 33,554,433/.test(text), `${id}: the decoded count is shown as a lower bound`);
    } else if (id === "seed_image_raster") {
      check(/Refused: An image in this file decodes, or would be drawn, at more than 256 MiB\./.test(text) && /refused before it was opened/.test(text), `${id}: refused with the plain image sentence, not opened`);
    } else if (id === "seed_xref_broken") {
      check(/Refused: The structure of this file cannot be vouched for/.test(text), `${id}: unaccounted is said`);
      check(await page.locator("#slip-body table.pages caption", { hasText: "Page by page" }).count() === 1, `${id}: the analysis still ran and shows its page report`);
    } else {
      check(/Accepted: every stream is within its limit\./.test(text) || id === "encrypted", `${id}: ${id === "encrypted" ? "encrypted is not counted" : "accepted"}`);
      if (id === "encrypted") check(/Refused: The structure of this file cannot be vouched for/.test(text) && /This PDF is encrypted\./.test(text), `${id}: stream check says unaccounted and the structure report says encrypted`);
      else check(await page.locator("#slip-body .proof .verdict.is-ok").count() >= 1 && /Identical to the native build\./.test(text), `${id}: the page report is identical to the native build`);
    }
    void seed;
  }
  check(consoleErrors.length === 0, `0 console errors (${consoleErrors.length}${consoleErrors.length ? ": " + consoleErrors.slice(0, 3).join(" | ") : ""})`);
  check(foreign.size === 0, `same-origin requests only (${foreign.size ? [...foreign].join(", ") : "none foreign"})`);
  const csp = await page.getAttribute('meta[http-equiv="Content-Security-Policy"]', "content");
  check(!/(^|[^-])unsafe-eval|unsafe-inline/.test(csp) && /script-src 'self' 'wasm-unsafe-eval'/.test(csp), "the CSP is unchanged: no unsafe-eval, no unsafe-inline");
  const build = await page.textContent("body");
  check(/(Built from main at|Local build) [0-9a-f]{12}/.test(build), "a build label in the convention form is shown");
} finally {
  await browser.close();
  server.close();
}
console.log(failures ? `${failures} check(s) failed` : "all checks passed");
process.exit(failures ? 1 : 0);
