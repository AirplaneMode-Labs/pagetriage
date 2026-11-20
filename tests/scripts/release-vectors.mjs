// Runs every case of tests/vectors/release/release.json through a release tool (the vendored scripts/release/release-tool.mjs),
// as a child process with a scrubbed environment, and compares the exit code, the first stderr line and the JSON reason with the
// vector (spec release 0.6.1, runtime spec/vectors/release/README.md). The cases and the mutation vocabulary are runtime's; this
// file is the pagetriage copy of its harness (runtime test/tools/lib.mjs applyReleaseMutation) and reads nothing outside the two
// paths it is given.
//
//   node tests/scripts/release-vectors.mjs <release-tool.mjs> <vectors/release directory>
//
// A case that applies on this OS and cannot be set up (a link the OS refuses) FAILS: it is never skipped. A case with
// platform "win32" runs only on Windows. Exit 0 when every case agrees, 1 otherwise.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const [toolArg, vectorsArg] = process.argv.slice(2);
if (!toolArg || !vectorsArg) { console.error("usage: release-vectors.mjs <release-tool.mjs> <vectors/release dir>"); process.exit(2); }
const tool = resolve(toolArg);
const releaseDir = resolve(vectorsArg);
const BANNER = "VERIFIED WITH THE PUBLISHED RFC 8032 TEST KEY: rehearsal only, not a release";
const sha = (b) => createHash("sha256").update(b).digest("hex");
const root = mkdtempSync(join(tmpdir(), "pagetriage-release-vectors-"));

function link(kind, target, path) {
  try {
    if (kind === "dir" && process.platform === "win32") symlinkSync(target, path, "junction");
    else symlinkSync(target, path, kind === "dir" ? "dir" : "file");
  } catch (e) {
    throw new Error(`cannot create a ${kind} link on ${process.platform} (${e.code ?? "error"}): the not_regular_file case cannot run here and must not be skipped`);
  }
}

function applyMutation(srcName, dest, mutation, work) {
  cpSync(join(releaseDir, srcName), dest, { recursive: true });
  const op = mutation?.op ?? "none";
  const file = (n) => join(dest, n);
  const textOf = (n) => readFileSync(file(n), "utf8");
  switch (op) {
    case "none": break;
    case "flip-byte": { const b = readFileSync(file(mutation.file)); b[mutation.offset ?? 0] ^= 0x01; writeFileSync(file(mutation.file), b); break; }
    case "truncate": { const b = readFileSync(file(mutation.file)); writeFileSync(file(mutation.file), b.subarray(0, b.length - (mutation.bytes ?? 1))); break; }
    case "remove": rmSync(file(mutation.file)); break;
    case "add-file": writeFileSync(file(mutation.file), mutation.content); break;
    case "sums-edit": { const lines = textOf("SHA256SUMS").split("\n"); const l = lines[mutation.line ?? 0]; lines[mutation.line ?? 0] = (l[0] === "0" ? "1" : "0") + l.slice(1); writeFileSync(file("SHA256SUMS"), lines.join("\n")); break; }
    case "sums-crlf": writeFileSync(file("SHA256SUMS"), textOf("SHA256SUMS").replace(/\n/g, "\r\n")); break;
    case "sums-reorder": { const lines = textOf("SHA256SUMS").split("\n").filter(Boolean).reverse(); writeFileSync(file("SHA256SUMS"), lines.join("\n") + "\n"); break; }
    case "manifest-publisher-edit": { const m = JSON.parse(textOf("release-manifest.json")); m.publisher = `${m.publisher} (edited)`; writeFileSync(file("release-manifest.json"), JSON.stringify(m, null, 2) + "\n"); break; }
    case "symlink-artifact": { const real = join(work, `real-${mutation.file}`); renameSync(file(mutation.file), real); link("file", real, file(mutation.file)); break; }
    case "junction-artifact": { const real = join(work, `real-dir-${mutation.file}`); mkdirSync(real); rmSync(file(mutation.file)); link("dir", real, file(mutation.file)); break; }
    case "subdir": mkdirSync(file(mutation.name ?? "sub")); break;
    case "symlink-dir": { const l = join(work, "dirlink"); link("dir", dest, l); return l; }
    default: throw new Error(`unknown mutation ${op}`);
  }
  return dest;
}

function listTree(dir) {
  return readdirSync(dir).sort().map((n) => { const p = join(dir, n); const st = statSync(p); return st.isFile() ? `${n}:${sha(readFileSync(p))}` : `${n}/`; }).join("|");
}

const cases = JSON.parse(readFileSync(join(releaseDir, "release.json"), "utf8"));
let pass = 0, failed = 0, skippedPlatform = 0;
const bad = (name, msg) => { failed++; console.log(`FAIL - ${name}: ${msg}`); };
const good = (name) => { pass++; console.log(`ok   - ${name}`); };

for (const c of cases) {
  if (c.platform !== undefined && c.platform !== process.platform) { skippedPlatform++; console.log(`n/a  - ${c.name} (platform ${c.platform} only; this is ${process.platform})`); continue; }
  const work = mkdtempSync(join(root, "case-"));
  try {
    const dest = join(work, "dir");
    const dir = applyMutation(c.dir, dest, c.mutation, work);
    const args = c.args.map((a) => (a.startsWith("@keys/") ? join(releaseDir, "keys", a.slice(6)) : a));
    const before = listTree(dest);
    // a scrubbed environment: PATH (and SystemRoot on Windows) only; SOURCE_DATE_EPOCH is not needed by verify or sign
    const env = { PATH: process.env.PATH ?? "", ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}) };
    const r = spawnSync(process.execPath, [tool, c.command ?? "verify", "--dir", dir, ...args], { encoding: "utf8", env });
    if (r.error) throw r.error;
    const first = (r.stderr ?? "").split("\n")[0];
    const problems = [];
    if (r.status !== c.expect.exit) problems.push(`exit ${r.status}, want ${c.expect.exit} (stderr: ${first})`);
    else if (c.expect.exit === 0) {
      if ((c.command ?? "verify") === "verify") {
        let out = {};
        try { out = JSON.parse(r.stdout); } catch { problems.push("stdout is not JSON"); }
        if (out.verdict !== "ok") problems.push(`verdict ${out.verdict}`);
        if (out.testKey !== c.expect.testKey) problems.push(`testKey ${out.testKey}, want ${c.expect.testKey}`);
        if (r.stderr.includes(BANNER) !== (c.expect.testKey === true)) problems.push("the test-key banner is not on stderr exactly when testKey is true");
      }
    } else if (c.expect.exit === 3) {
      if (first !== `refused: ${c.expect.reason}`) problems.push(`first stderr line '${first}', want 'refused: ${c.expect.reason}'`);
      let out = null;
      try { out = JSON.parse(r.stdout); } catch { /* reported below */ }
      if (!out || out.verdict !== "refused" || out.reason !== c.expect.reason) problems.push(`stdout ${JSON.stringify(r.stdout.slice(0, 120))}, want {"verdict":"refused","reason":"${c.expect.reason}"}`);
    } else {
      if (!new RegExp(`^usage: ${c.expect.reason}: .+`).test(first)) problems.push(`first stderr line '${first}', want 'usage: ${c.expect.reason}: ...'`);
      if (r.stdout !== "") problems.push("stdout is not empty on a usage error");
    }
    // a refusal and a usage error never change the directory they were pointed at
    if (c.expect.exit !== 0 && existsSync(dest) && listTree(dest) !== before) problems.push("the directory changed");
    if (problems.length) bad(c.name, problems.join("; ")); else good(`${c.name}: ${c.expect.exit} ${c.expect.reason ?? "ok"}`);
  } catch (e) {
    bad(c.name, e.message);
  }
}
rmSync(root, { recursive: true, force: true });
console.log(`${pass} cases agree, ${failed} do not, ${skippedPlatform} are for another platform (${cases.length} in release.json)`);
if (cases.length < 36) { console.log("FAIL - release.json has fewer than the 36 specified cases"); process.exit(1); }
process.exit(failed ? 1 : 0);
