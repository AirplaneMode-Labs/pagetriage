// The planted edits of tests/scripts/benchmarks.sh, in Node: the test already needs Node 22 for the checker, and a second interpreter (python or python3, which on
// Windows may be a Microsoft Store stub that prints a message and exits non-zero) is one more thing a clean machine may not have.
// Files are read and written as UTF-8 with no newline translation, so a planted edit changes exactly the bytes it names.
//
//   node benchmarks-plant.mjs replace <file> <old> <new>             every occurrence of <old>; exit 1 when <old> is not in the file
//   node benchmarks-plant.mjs drop-lines <file> <starts|has> <text>  removes every line that starts with, or holds, <text>
//   node benchmarks-plant.mjs drop-first-column <file>               removes the first cell of every line of a CSV (the "date" column)
//   node benchmarks-plant.mjs crlf <dir>                             rewrites every .md, .json, .csv and .html file under <dir> with CRLF line endings
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const [cmd, target, ...rest] = process.argv.slice(2);
const die = (m) => { process.stderr.write(m + "\n"); process.exit(1); };
const rewrite = (file, fn) => writeFileSync(file, fn(readFileSync(file, "utf8")), "utf8");

if (cmd === "replace") {
  const [oldText, newText] = rest;
  if (oldText === undefined || newText === undefined) die("replace needs <file> <old> <new>");
  const text = readFileSync(target, "utf8");
  if (!text.includes(oldText)) die(`the planted edit's old text is not in ${target}: ${oldText.slice(0, 60)}`);
  writeFileSync(target, text.split(oldText).join(newText), "utf8");
} else if (cmd === "drop-lines") {
  const [mode, needle] = rest;
  if (!["starts", "has"].includes(mode) || !needle) die("drop-lines needs <file> <starts|has> <text>");
  let dropped = 0;
  rewrite(target, (t) => t.split("\n").filter((l) => { const hit = mode === "starts" ? l.startsWith(needle) : l.includes(needle); if (hit) dropped++; return !hit; }).join("\n"));
  if (dropped === 0) die(`the planted edit dropped no line of ${target}: ${needle}`);
} else if (cmd === "drop-first-column") {
  rewrite(target, (t) => t.split("\n").map((r) => (r === "" ? r : r.slice(r.indexOf(",") + 1))).join("\n"));
} else if (cmd === "crlf") {
  const walk = (dir) => {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      if (statSync(p).isDirectory()) walk(p);
      else if (/\.(md|json|csv|html)$/.test(name)) rewrite(p, (t) => t.replace(/\r?\n/g, "\r\n"));
    }
  };
  walk(target);
} else {
  die("usage: benchmarks-plant.mjs replace|drop-lines|drop-first-column|crlf ...");
}
