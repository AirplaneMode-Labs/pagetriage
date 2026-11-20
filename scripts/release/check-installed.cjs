// One real call of the INSTALLED npm package, and proof that the installed copy is what ran (TD-106, Sprint 7).
//
//   cd <fresh project> && node <repo>/scripts/release/check-installed.cjs <golden-dir> <project-dir>
//
// <golden-dir> is tests/golden of the checkout (test data only). Exits 1 unless
//   - @airplanemode/pagetriage resolves under <project-dir>/node_modules (not to the source tree, not to a sibling),
//   - analyse_page on the synthetic golden page blank_speckle.pgm returns the golden report byte for byte, and
//   - analyse_pdf_structure on the synthetic golden PDF native_latin.pdf returns the golden structure report byte for byte
//     (the tarball is the PDF-enabled build).
"use strict";
const fs = require("fs");
const path = require("path");

const [golden, project] = process.argv.slice(2);
if (!golden || !project) { console.error("usage: check-installed.cjs <golden-dir> <project-dir>"); process.exit(2); }
let ok = true;
const check = (cond, what) => { console.log((cond ? "ok   " : "FAIL ") + what); ok = ok && cond; };

const projectReal = fs.realpathSync.native(project);
const resolved = fs.realpathSync.native(require.resolve("@airplanemode/pagetriage", { paths: [projectReal] }));
console.log("module: " + resolved);
const rel = path.relative(path.join(projectReal, "node_modules"), resolved);
check(rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel), "the package resolves under the fresh project's node_modules");
const wasm = require(resolved);

function readPgm(file) {
  const data = fs.readFileSync(file);
  let pos = 0;
  const tok = [];
  const sp = (b) => b === 0x20 || (b >= 0x09 && b <= 0x0d);
  while (tok.length < 4) { while (sp(data[pos])) pos++; const s = pos; while (!sp(data[pos])) pos++; tok.push(data.subarray(s, pos).toString("ascii")); }
  pos++;
  return { w: Number(tok[1]), h: Number(tok[2]), pixels: new Uint8Array(data.subarray(pos)) };
}
const page = readPgm(path.join(golden, "inputs", "blank_speckle.pgm"));
const got = wasm.analyse_page(page.pixels, undefined, page.w, page.h, 150, undefined, '{"debug":true}') + "\n";
check(got === fs.readFileSync(path.join(golden, "expected", "blank_speckle.json"), "utf8"), "analyse_page on the golden page blank_speckle.pgm is byte-equal to its golden report");
check(typeof wasm.analyse_pdf_structure === "function", "the package exports analyse_pdf_structure (PDF build)");
if (typeof wasm.analyse_pdf_structure === "function") {
  const pdf = new Uint8Array(fs.readFileSync(path.join(golden, "pdf", "native_latin.pdf")));
  const want = fs.readFileSync(path.join(golden, "pdf_expected", "native_latin.json"), "utf8");
  check(wasm.analyse_pdf_structure(pdf) + "\n" === want, "analyse_pdf_structure on the golden PDF native_latin.pdf is byte-equal to its golden report");
}
process.exit(ok ? 0 : 1);
