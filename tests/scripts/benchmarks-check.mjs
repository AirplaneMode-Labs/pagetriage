// The benchmark rule (owner decision, 20 Nov 2026): every figure quoted anywhere has its raw file committed under docs/benchmarks/.
// Run by tests/scripts/benchmarks.sh on the real tree and on scratch copies with one thing broken (the copies must fail).
//
//   ROOT=<repository root> node tests/scripts/benchmarks-check.mjs      prints "ok   - ..." and "FAIL - ..." lines
//
// A. Provenance. Every file in docs/benchmarks/ (except README.md and claims.json) has a row in the index of
//    docs/benchmarks/README.md and every row names a file that exists; every CSV row and every JSON record carries a date, a commit, a
//    machine and a command and says "not measured on 8 GB"; the index row repeats the file's own date, commit and machine; the
//    reproduce cell names the file; no machine is an 8 GB one; the standing line about 8 GB laptops is in the index.
// B. Claims. docs/benchmarks/claims.json lists the figures that README.md, docs/ and the demo quote. Each claim has the text it quotes
//    (found in its document), and each check under it is either a row (or a derived value) of a committed file, or the words
//    "raw data not kept" next to the quote. A figure that does not equal its row fails; so does a quote that has left its document.
// C. Coverage in the other direction. In the README Benchmarks table, the demo's results table and the "What was measured" table of the
//    write-up, every number in the result and trust cells lies inside a claim's quote; and any line elsewhere in README.md, docs/*.md,
//    bench/README.md and site/index.html that quotes a timing, a throughput or a byte count is inside a claim's quote or says "raw data not kept".
//    Each docs/detectors/*.md page with a results section names its raw files (`Raw results:`) or says "raw data not kept".
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";

const ROOT = process.env.ROOT;
if (!ROOT) throw new Error("ROOT is required");
const out = [];
const ok = (m) => out.push(`ok   - ${m}`);
const bad = (m) => out.push(`FAIL - ${m}`);
const check = (cond, m) => (cond ? ok(m) : bad(m));
// CRLF is read as LF: .gitattributes checks every text file out with LF (tests/scripts/benchmarks.sh asserts it), but a checker whose answer depended on that
// would count the `|---|` row of a table as a data row on a CRLF copy (the separator test ends in `|$`). benchmarks.sh runs a CRLF copy and wants the same output.
const read = (rel) => readFileSync(join(ROOT, rel), "utf8").replace(/\r\n/g, "\n");
const has = (rel) => existsSync(join(ROOT, rel));
const BEN = "docs/benchmarks";
const NOT_KEPT = "raw data not kept";
const EIGHT = "not measured on 8 GB";

// ---- parsing -------------------------------------------------------------------------------------------------
function parseCsv(text) {
  const rows = [];
  let row = [], cell = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') q = false; else cell += c; }
    else if (c === '"') q = true;
    else if (c === ",") { row.push(cell); cell = ""; }
    else if (c === "\n") { row.push(cell); rows.push(row); row = []; cell = ""; }
    else if (c !== "\r") cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  const head = rows.shift() ?? [];
  return { head, rows: rows.filter((r) => r.length > 1 || r[0] !== "").map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ""]))) };
}
const cells = (line) => line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
const norm = (s) => s.replace(/\s+/g, " ").trim();
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// a number as it is written in prose: not part of a longer number or a word
const tokenRe = (t) => new RegExp(`(?<![\\w.,])${esc(t)}(?![\\w]|[.,]\\d)`);
const hasToken = (text, t) => tokenRe(t).test(text);

// ---- A. provenance ---------------------------------------------------------------------------------------------
const files = has(BEN) ? readdirSync(join(ROOT, BEN)).filter((f) => f !== "README.md" && f !== "claims.json" && statSync(join(ROOT, BEN, f)).isFile()).sort() : [];
check(files.length >= 6, `docs/benchmarks/ holds raw files (${files.length})`);
check(has(`${BEN}/README.md`), "docs/benchmarks/README.md exists");
const indexText = has(`${BEN}/README.md`) ? read(`${BEN}/README.md`) : "";
check(/Nothing here was measured on an 8 GB laptop unless a file says so/.test(indexText), "the index carries the standing line: nothing here was measured on an 8 GB laptop unless a file says so");
const indexRows = new Map();
for (const line of indexText.split("\n")) {
  if (!line.startsWith("|")) continue;
  const c = cells(line);
  const m = /^`([^`]+)`$/.exec(c[0] ?? "");
  if (m && c.length >= 6) indexRows.set(m[1], c);
}
for (const f of files) check(indexRows.has(f), `${f} has a row in the index of docs/benchmarks/README.md`);
for (const f of indexRows.keys()) check(files.includes(f), `the index row for ${f} names a file that exists`);

const provenance = new Map(); // file -> { dates, commits, machines }
const rowsOf = new Map(); // csv file -> rows
const recordOf = new Map(); // json file -> record
const RECORD_SCHEMA = "pagetriage-bench-record-1";
for (const f of files) {
  const text = read(`${BEN}/${f}`);
  check(Buffer.byteLength(text) < 5 * 1024 * 1024, `${f} is under 5 MB`);
  const dates = new Set(), commits = new Set(), machines = new Set(), commands = new Set();
  if (f.endsWith(".csv")) {
    const { head, rows } = parseCsv(text);
    rowsOf.set(f, rows);
    const need = ["date", "machine", "commit", "command", "eight_gb_laptop"];
    check(need.every((h) => head.includes(h)), `${f} has the columns ${need.join(", ")}${need.every((h) => head.includes(h)) ? "" : " (it lacks " + need.filter((h) => !head.includes(h)).join(", ") + ")"}`);
    check(rows.length > 0, `${f} has rows (${rows.length})`);
    for (const [i, r] of rows.entries()) {
      for (const h of need) if (!r[h]) bad(`${f} row ${i + 2} has an empty ${h}`);
      if (r.date && !/^\d{4}-\d{2}-\d{2}$/.test(r.date)) bad(`${f} row ${i + 2}: date ${r.date} is not YYYY-MM-DD`);
      if (r.eight_gb_laptop !== EIGHT && !(r.eight_gb_laptop ?? "").startsWith("measured on 8 GB:")) bad(`${f} row ${i + 2}: eight_gb_laptop is neither "${EIGHT}" nor "measured on 8 GB: <the machine>"`);
      dates.add(r.date); commits.add(r.commit); machines.add(r.machine); commands.add(r.command);
    }
    check(![...dates, ...commits, ...machines, ...commands].some((v) => !v), `${f}: every row names its date, commit, machine and command`);
  } else if (f.endsWith(".json")) {
    let doc;
    try { doc = JSON.parse(text); } catch (e) { bad(`${f} is not valid JSON: ${e.message}`); continue; }
    recordOf.set(f, doc);
    const need = ["schema", "name", "date", "commit", "machine", "command", "exit_code", "wall_seconds", "eight_gb_laptop", "stdout", "stderr"];
    const missing = need.filter((k) => !(k in doc));
    check(missing.length === 0, `${f} has the fields of a bench record${missing.length ? " (lacks " + missing.join(", ") + ")" : ""}`);
    check(doc.schema === RECORD_SCHEMA, `${f} is a ${RECORD_SCHEMA}`);
    for (const k of ["date", "commit", "machine", "command"]) check(typeof doc[k] === "string" && doc[k].trim() !== "", `${f} names its ${k}`);
    check(/^\d{4}-\d{2}-\d{2}$/.test(doc.date ?? ""), `${f}: date ${doc.date} is YYYY-MM-DD`);
    check(doc.exit_code === 0, `${f}: the command exited 0 (${doc.exit_code})`);
    check(Array.isArray(doc.stdout) && doc.stdout.length > 0, `${f} kept the command's output`);
    check(doc.eight_gb_laptop === EIGHT || (typeof doc.eight_gb_laptop === "string" && doc.eight_gb_laptop.startsWith("measured on 8 GB:") && doc.eight_gb_laptop.length > 25), `${f} says "${EIGHT}" or "measured on 8 GB: <the machine>"`);
    check(!/\/Users\/|\/home\/|\/private\/tmp|\/var\/folders|[A-Za-z]:\\Users\\/.test(text), `${f} holds no home or builder path`);
    dates.add(doc.date); commits.add(doc.commit); machines.add(doc.machine); commands.add(doc.command);
  }
  const says8 = f.endsWith(".json") ? String(recordOf.get(f)?.eight_gb_laptop ?? "").startsWith("measured on 8 GB:") : (rowsOf.get(f) ?? []).some((r) => String(r.eight_gb_laptop).startsWith("measured on 8 GB:"));
  for (const m of machines) {
    const is8 = /(^|[^\d.])8(\.\d+)? ?(GB|GiB)\b/.test(m);
    if (says8) check(is8, `${f}: it says "measured on 8 GB", so its machine must be an 8 GB laptop ("${m}")`);
    else check(!is8, `${f}: machine "${m}" is an 8 GB laptop but the file does not say it was measured on 8 GB`);
  }
  provenance.set(f, { dates, commits, machines, commands });
  const row = indexRows.get(f);
  if (row) {
    const [, , date, commit, machine, reproduce] = row;
    for (const d of dates) check(date.includes(d), `index row of ${f} gives the date ${d}`);
    for (const c of commits) check(commit.includes(c), `index row of ${f} gives the commit ${c}`);
    for (const m of machines) check(machine.includes(m), `index row of ${f} gives the machine "${m}"`);
    check(reproduce.includes(`docs/benchmarks/${f}`), `index row of ${f} has a reproduce command that writes docs/benchmarks/${f}`);
    if (f.endsWith(".json")) {
      const doc = recordOf.get(f);
      check(doc && reproduce.includes(doc.command), `index row of ${f} gives the recorded command (${doc && doc.command})`);
    }
  }
}

// ---- B. claims -------------------------------------------------------------------------------------------------
let claims = [];
try { claims = JSON.parse(read(`${BEN}/claims.json`)).claims ?? []; } catch (e) { bad(`docs/benchmarks/claims.json cannot be read: ${e.message}`); }
check(claims.length >= 20, `claims.json lists the quoted figures (${claims.length})`);
const docCache = new Map();
const docText = (rel) => { if (!docCache.has(rel)) docCache.set(rel, has(rel) ? read(rel) : null); return docCache.get(rel); };
// the text that must carry "raw data not kept" for a quote: its own table row or <td>, else its paragraph
function contextOf(text, quote) {
  for (const line of text.split("\n")) if (norm(line).includes(quote) && (line.trimStart().startsWith("|") || /<t[dr]/.test(line))) return norm(line);
  for (const p of text.split(/\n\s*\n/)) if (norm(p).includes(quote)) return norm(p);
  return "";
}
const quotesByDoc = new Map(); // doc -> [{quote, notKept}]
const ids = new Set();
function pick(rows, where) {
  return rows.filter((r) => Object.entries(where ?? {}).every(([k, v]) => (Array.isArray(v) ? v.includes(r[k]) : r[k] === v)));
}
// a number written to `d` digits: rounded, or floored / raised to the next step (the way a range such as "4 to 9 MB" is written to contain its values)
function fmt(x, d, mode) {
  const f = 10 ** d;
  const y = mode === "floor" ? Math.floor(x * f + 1e-9) / f : mode === "ceil" ? Math.ceil(x * f - 1e-9) / f : Math.round(x * f + Math.sign(x) * 1e-7) / f;
  return y.toFixed(d);
}
// numbers that are not results: sprint numbers, version numbers (Chrome 157.0.8103.79, 1.0.0-rc.1), dates, and what a claim never quotes
const NOT_FIGURES = [/gzip -9/g, /\b8 GB\b/g, /\b\d+(?:st|nd|rd|th)\b/g, /%\d\d/g, /\bSprints? \d+(?: and \d+)?/g, /\b\d+\.\d+\.\d+(?:\.\d+)?(?:-rc\.\d+)?/g, /\b\d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*( \d{4})?/g, /\b20\d\d-\d\d-\d\d\b/g, /\b20\d\d\b/g];
const digitsLeft = (s) => {
  for (const re of NOT_FIGURES) s = s.replace(re, " ");
  return (s.match(/(?<![\w])\d[\d,.]*/g) ?? []).map((x) => x.replace(/[.,]+$/, "")).filter((x) => /\d/.test(x));
};
for (const c of claims) {
  const label = `claim ${c.id}`;
  check(c.id && !ids.has(c.id), `${label}: the id is unique`); ids.add(c.id);
  const text = docText(c.doc);
  if (text === null) { bad(`${label}: ${c.doc} exists`); continue; }
  const flat = norm(text);
  const quote = norm(c.quote ?? "");
  const at = flat.indexOf(quote);
  check(quote.length > 0 && at >= 0, `${label}: the document ${c.doc} still says "${quote.slice(0, 70)}${quote.length > 70 ? "..." : ""}"`);
  if (at < 0) continue;
  if (!quotesByDoc.has(c.doc)) quotesByDoc.set(c.doc, []);
  quotesByDoc.get(c.doc).push({ quote });
  check((c.checks ?? []).length > 0, `${label}: it has at least one check`);
  const verified = new Set(c.config ?? []); // every number of the quote is either checked against a row or named here as a protocol parameter
  const claimed = (...ts) => ts.forEach((t) => verified.add(String(t)));
  for (const [n, k] of (c.checks ?? []).entries()) {
    const w = `${label} check ${n + 1}`;
    if (k.not_kept) {
      check(typeof k.not_kept === "string" && k.not_kept.length > 10, `${w}: says why the raw data is not kept`);
      check(contextOf(text, quote).toLowerCase().includes(NOT_KEPT), `${w}: the table row or paragraph of the quote in ${c.doc} says "${NOT_KEPT}"`);
      claimed(...digitsLeft(quote));
      continue;
    }
    if (k.protocol) {
      // a number that is a setting of the experiment or a target, not a result (the quote's numbers are all taken as such)
      check(typeof k.protocol === "string" && k.protocol.length > 10, `${w}: says what the numbers of the quote are (a setting, a target)`);
      claimed(...digitsLeft(quote));
      continue;
    }
    if (k.file && !files.includes(k.file)) { bad(`${w}: ${k.file} is not a committed file in docs/benchmarks/`); continue; }
    if (k.file && k.file.endsWith(".json")) {
      const doc = recordOf.get(k.file);
      const want = k.match ?? k.stdout;
      const test = k.match ? (l) => new RegExp(k.match).test(l) : (l) => l.includes(k.stdout);
      const line = (doc?.stdout ?? []).find(test);
      if (want) check(line !== undefined, `${w}: ${k.file} has the output line ${k.match ? "matching /" + k.match + "/" : '"' + k.stdout + '"'}`);
      for (const f of k.figures ?? []) { check(hasToken(quote, f) && hasToken(line ?? "", f), `${w}: ${f} is in the quote and in the output line of ${k.file}`); claimed(f); }
      for (const v of k.values ?? []) {
        const m = new RegExp(v.re, "m").exec(line ?? "") ?? new RegExp(v.re, "m").exec((doc?.stdout ?? []).join("\n"));
        let got = m ? fmt(((v.sub_from ?? 0) ? v.sub_from - Number(m[v.group ?? 1]) : Number(m[v.group ?? 1])) / (v.per ?? 1), v.digits ?? 0, v.round) : "NaN";
        if (v.commas && got !== "NaN") got = Number(got).toLocaleString("en-US");
        check(got === v.text && hasToken(quote, v.text), `${w}: the number /${v.re}/ of ${k.file} is ${got} to ${v.digits ?? 0} digits (the quote says ${v.text})`);
        claimed(v.text);
      }
      for (const [field, sub] of Object.entries(k.meta ?? {})) {
        check(String(doc?.[field] ?? "").includes(sub) && quote.includes(sub), `${w}: the ${field} of ${k.file} contains "${sub}", which is in the quote`);
        claimed(...digitsLeft(sub));
      }
      if (k.mean) {
        const re = new RegExp(k.mean.lines);
        const picked = (doc?.stdout ?? []).map((l) => re.exec(l)).filter((m) => m && !(k.mean.exclude ?? []).includes(m.groups.key));
        const vals = picked.map((m) => Number(m.groups[k.mean.field]));
        const mean = vals.reduce((a, b) => a + b, 0) / (vals.length || 1);
        check(vals.length === k.mean.count && hasToken(quote, String(k.mean.count)), `${w}: ${k.mean.count} rows of ${k.file} are averaged (${vals.length}) and the quote says ${k.mean.count}`);
        check(fmt(mean, k.mean.digits, k.mean.round) === k.mean.text && hasToken(quote, k.mean.text), `${w}: the mean of ${k.mean.field} over those rows is ${fmt(mean, k.mean.digits, k.mean.round)} (the quote says ${k.mean.text})`);
        claimed(k.mean.count, k.mean.text);
      }
      check((k.figures ?? []).length > 0 || !!k.mean || (k.values ?? []).length > 0 || Object.keys(k.meta ?? {}).length > 0, `${w}: it names the figures it checks`);
      continue;
    }
    if (k.file) {
      const rows = rowsOf.get(k.file) ?? [];
      const sel = pick(rows, k.where);
      if (k.column && k.agg) {
        check(sel.length > 0, `${w}: ${k.file} has the rows ${JSON.stringify(k.where ?? {})} (${sel.length})`);
        const vals = sel.map((r) => Number(r[k.column]) / (k.per ?? 1));
        const v = k.agg === "min" ? Math.min(...vals) : Math.max(...vals);
        const want = Number.isFinite(v) ? fmt(v, k.digits ?? 0, k.round) : "NaN";
        check(want === k.text && hasToken(quote, k.text), `${w}: the ${k.agg} of ${k.column}${k.per ? " / " + k.per : ""} over ${sel.length} rows of ${k.file} is ${want} (${k.round ?? "rounded"}), the quote says ${k.text}`);
        claimed(k.text);
        continue;
      }
      check(sel.length === 1, `${w}: ${k.file} has exactly one row ${JSON.stringify(k.where ?? {})} (${sel.length})`);
      if (sel.length !== 1) continue;
      const row = sel[0];
      for (const [col, text2] of Object.entries(k.expect ?? {})) {
        const cell = (k.commas ?? []).includes(col) ? text2.replace(/,/g, "") : text2;
        check(row[col] === cell && hasToken(quote, text2), `${w}: ${col} ${text2} equals the row of ${k.file} (${row[col]}) and is in the quote`);
        claimed(text2);
      }
      for (const [col, d] of Object.entries(k.derive ?? {})) {
        const v = (Number(row[col]) - (d.minus ? Number(row[d.minus]) : 0)) / d.per;
        const want = d.digits === undefined ? String(v) : fmt(v, d.digits, d.round);
        check(want === d.text && hasToken(quote, d.text), `${w}: (${col}${d.minus ? " - " + d.minus : ""}) / ${d.per} is ${want} (the quote says ${d.text})`);
        claimed(d.text);
      }
      for (const d of k.extract ?? []) {
        const m = new RegExp(d.re).exec(row[d.col] ?? "");
        const v = m ? Number(m[1]) / (d.per ?? 1) : NaN;
        let want = Number.isFinite(v) ? fmt(v, d.digits ?? 0, d.round) : "NaN";
        if (d.commas && want !== "NaN") want = Number(want).toLocaleString("en-US");
        check(want === d.text && hasToken(quote, d.text), `${w}: the number in ${d.col} (/${d.re}/) / ${d.per ?? 1} is ${want} (the quote says ${d.text})`);
        claimed(d.text);
      }
      for (const [col, sub] of Object.entries(k.contains ?? {})) {
        check((row[col] ?? "").includes(sub) && quote.includes(sub), `${w}: ${col} of the row of ${k.file} contains "${sub}", which is in the quote`);
        claimed(...digitsLeft(sub));
      }
      check(Object.keys(k.expect ?? {}).length + Object.keys(k.derive ?? {}).length + (k.extract ?? []).length + Object.keys(k.contains ?? {}).length > 0, `${w}: it checks at least one value`);
    }
  }
  const unaccounted = digitsLeft(quote).filter((t) => !verified.has(t));
  check(unaccounted.length === 0, `${label}: every number in the quote is checked against a row or named in config (${unaccounted.length ? "unaccounted: " + [...new Set(unaccounted)].slice(0, 8).join(" ") : digitsLeft(quote).length + " numbers"})`);
}

// ---- C. coverage -----------------------------------------------------------------------------------------------
const covered = (doc, line) => {
  const flat = norm(line);
  let rest = flat;
  for (const { quote } of quotesByDoc.get(doc) ?? []) rest = rest.split(quote).join(" ");
  return { rest, flat };
};
// the numbers of a table cell that no claim quote accounts for
function uncoveredIn(doc, cell) {
  const { rest, flat } = covered(doc, cell);
  if (flat.toLowerCase().includes(NOT_KEPT)) return [];
  return digitsLeft(rest.replace(/[`*_]/g, ""));
}
// README: the Benchmarks table
{
  const text = read("README.md");
  const a = text.indexOf("\n## Benchmarks"), b = text.indexOf("\n## Limitations");
  check(a >= 0 && b > a, "README.md has the Benchmarks section before Limitations");
  let rowsSeen = 0;
  for (const line of text.slice(a, b).split("\n")) {
    if (!line.startsWith("|") || /^\|[-\s|]+\|$/.test(line) || /^\|\s*What was measured/.test(line)) continue;
    rowsSeen++;
    const c = cells(line);
    const label = c[0].slice(0, 60);
    for (const idx of [1, 3]) {
      const left = uncoveredIn("README.md", c[idx] ?? "");
      check(left.length === 0, `README Benchmarks row "${label}": every number in ${idx === 1 ? "the result" : "the trust"} cell has a claim (${left.length ? "unclaimed: " + left.slice(0, 5).join(" ") : "all claimed"})`);
    }
  }
  check(rowsSeen >= 10, `the README Benchmarks table has its rows (${rowsSeen})`);
  check(/docs\/benchmarks\//.test(text.slice(a, b)), "the README Benchmarks section links docs/benchmarks/");
}
// the demo: its results table
{
  const html = read("site/index.html");
  const m = /<table class="grid-table">[\s\S]*?<\/table>/.exec(html);
  check(!!m, "site/index.html has its results table");
  const rows = m ? m[0].split("</tr>").filter((r) => r.includes("<td")) : [];
  for (const r of rows) {
    const tds = [...r.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((x) => x[1].replace(/<[^>]+>/g, "").trim());
    for (const idx of [1, 2]) {
      const left = uncoveredIn("site/index.html", tds[idx] ?? "");
      check(left.length === 0, `demo results row "${(tds[0] ?? "").slice(0, 50)}": every number in the ${idx === 1 ? "result" : "trust"} cell has a claim (${left.length ? "unclaimed: " + left.slice(0, 5).join(" ") : "all claimed"})`);
    }
  }
  check(/github\.com\/AirplaneMode-Labs\/pagetriage\/(tree|blob)\/main\/docs\/benchmarks\/?(["#])/.test(html), "the demo links the docs/benchmarks/ folder on GitHub");
}
// the write-up: "What was measured"
{
  const text = read("docs/writeup-1.0-draft.md");
  const a = text.indexOf("## What was measured"), b = text.indexOf("## On the 8 GB");
  check(a >= 0 && b > a, "the write-up has 'What was measured'");
  for (const line of text.slice(a, b).split("\n")) {
    if (!line.startsWith("|") || /^\|[-\s|]+\|$/.test(line) || /^\|\s*What\s*\|/.test(line)) continue;
    const c = cells(line);
    for (const idx of [1, 3]) {
      const left = uncoveredIn("docs/writeup-1.0-draft.md", c[idx] ?? "");
      check(left.length === 0, `write-up row "${c[0].slice(0, 50)}": every number in ${idx === 1 ? "the result" : "the caveat"} cell has a claim (${left.length ? "unclaimed: " + left.slice(0, 5).join(" ") : "all claimed"})`);
    }
  }
}
// elsewhere: a line that quotes a timing, a throughput or a byte count
const LINT = [
  /\d[\d,.]*\s?ms\b/, /\d[\d,.]*\s?s\/MP\b/, /\d\s?MP\/s\b/, /\d\s?megapixels per second/, /\d[\d,]*\s?(KB|MB)\s+(peak|gzipped)/, /\bpeak\b[^.|]*\d[\d,.]*\s?(MB|GB|KB)/,
  /\d{1,3}(,\d{3})+\s+bytes\s+(raw|gzip)/, /\d{1,3}(,\d{3})+ (bytes )?(raw|gzipped)/, /\d\d\d,\d\d\d bytes gzipped/, /\bgzipped\b[^.|]*\d{1,3},\d{3}/,
];
const detectorPages = [...(has("docs/detectors") ? readdirSync(join(ROOT, "docs/detectors")).filter((x) => x.endsWith(".md")).sort().map((f) => `docs/detectors/${f}`) : []), "docs/prepare.md"];
const lintDocs = ["README.md", "bench/README.md", "site/index.html", ...(has("docs") ? readdirSync(join(ROOT, "docs")).filter((f) => f.endsWith(".md") && f !== "RELEASING.md").map((f) => `docs/${f}`) : []), ...detectorPages.filter((f) => f.startsWith("docs/detectors/"))];
// units of text: a table row is one unit, a paragraph (lines up to a blank line) is one, a line of the demo's HTML is one
function units(text, html) {
  if (html) return text.split("\n").map((l) => l.replace(/<[^>]+>/g, " "));
  const out = [];
  let cur = [];
  const flush = () => { if (cur.length) out.push(cur.join(" ")); cur = []; };
  for (const l of text.split("\n")) {
    if (l.trim() === "") flush();
    else if (l.trimStart().startsWith("|")) { flush(); out.push(l); }
    else cur.push(l);
  }
  flush();
  return out;
}
for (const doc of lintDocs) {
  const text = docText(doc);
  if (text === null) continue;
  let hits = 0, bare = [];
  for (const unit of units(text, doc.endsWith(".html"))) {
    const flat = norm(unit);
    if (!LINT.some((re) => re.test(flat))) continue;
    hits++;
    if (flat.toLowerCase().includes(NOT_KEPT)) continue;
    let rest = flat;
    for (const { quote } of quotesByDoc.get(doc) ?? []) rest = rest.split(quote).join(" ");
    const stripped = rest.replace(/[`*_]/g, "");
    if (!LINT.some((re) => re.test(stripped))) continue;
    bare.push(flat.slice(0, 400));
  }
  check(bare.length === 0, `${doc}: every timing, throughput or byte-count line has a claim or says "${NOT_KEPT}" (${hits} such lines${bare.length ? "; unclaimed: " + bare.slice(0, 40).join(" || ") : ""})`);
}
// the detector pages (and docs/prepare.md): a results section names its raw files
for (const rel of detectorPages) {
  if (!has(rel)) continue;
  const text = read(rel);
  const hasResults = /^##+ .*(Measured|Results|Evaluation|Seen on real data|Cost|Accuracy|Benchmark|size)/im.test(text);
  if (!hasResults) continue;
  const line = text.split("\n").find((l) => /^\*{0,2}Raw results:?\*{0,2}/.test(l));
  if (!line) { bad(`${rel}: a results section needs a "Raw results:" line naming docs/benchmarks files, or "${NOT_KEPT}"`); continue; }
  const named = [...line.matchAll(/`?docs\/benchmarks\/([A-Za-z0-9._-]+)`?/g)].map((m) => m[1]).filter((n) => n !== "README.md");
  const missing = named.filter((n) => !files.includes(n));
  check(missing.length === 0 && (named.length > 0 || line.toLowerCase().includes(NOT_KEPT)), `${rel}: its Raw results line names committed files${missing.length ? " (not committed: " + missing.join(", ") + ")" : ""}`);
}
console.log(out.join("\n"));
