# The WASM call dockit uses: `analyse_pdf_structure`

Status: Sprint 5 (18 Nov 2026). This page documents one existing call of the existing browser build. Its behaviour did
not change in Sprint 5: the reports are byte-identical to the native and Python builds (`scripts/determinism.sh`, golden diff
empty). The only source edits are rustdoc fixes (three doc comments and one lint attribute, BUG-T2-S4-22); everything else
added is this page, `docs/benchmarks/wasm-structure.csv` and the scripts that check and produce them. Every timing and size below was measured on Apple M5 Pro 48 GB (darwin 27.2.0 arm64, 18 cores) in Chrome 157.0.8103.79; nothing was
measured on an 8 GB laptop (**not measured on 8 GB**).

dockit (the offline PDF question-answering app) needs one thing from pagetriage: for an uploaded PDF, which pages hold a
readable text layer, so that text can be extracted from those pages and the rest can be refused. The call is
`analyse_pdf_structure(bytes, opts_json?) -> string`, run in a Web Worker, on the raw bytes, with no rendering and no
pixels. It reads the file's structure (pages, content streams, fonts); it does no OCR and loads no model.

## Build

<!-- wasm-api:build:start -->
```sh
PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm bash scripts/build-wasm.sh
```
<!-- wasm-api:build:end -->

Needs the `wasm32-unknown-unknown` target (`rust-toolchain.toml` adds it), the `wasm-bindgen` CLI at the version
pinned in `crates/pagetriage-wasm/Cargo.toml` (`=0.2.129`; `scripts/build-wasm.sh` refuses any other) and `wasm-opt`.
Output: `dist/wasm/web/pagetriage.js` and `dist/wasm/web/pagetriage_bg.wasm` (for browsers and bundlers), and
`dist/wasm/nodejs/` (used by the determinism tests). Without `PAGETRIAGE_WASM_FEATURES=pdf` the call does not exist:
the default build is pixel-only and smaller.

`scripts/determinism.sh` and `scripts/build-site.sh` use `dist/wasm` for the pixel-only build and `dist/wasm-pdf` for the
PDF build. In a checkout where those have run, build the dockit package with `WASM_OUT=dist/wasm-pdf` to keep the
pixel-only output; the files are the same bytes. On 18 Nov 2026 the SHA-256 of `pagetriage_bg.wasm` built into
`dist/wasm` and into `dist/wasm-pdf` was identical (`30acd658b664...`).

Size of `pagetriage_bg.wasm` (this build): 2,335,481 bytes raw, 854,940 bytes with `gzip -9` (the figure
`scripts/check-wasm-size.sh` checks against its 1,000,000-byte budget). GitHub Pages serves it compressed.

## Loading it

```js
import init, { analyse_pdf_structure, version } from "./pkg/pagetriage.js";
const wasm = await init({ module_or_path: new URL("./pkg/pagetriage_bg.wasm", import.meta.url) });
const json = analyse_pdf_structure(new Uint8Array(arrayBuffer));   // or (bytes, optsJson)
const report = JSON.parse(json);
```

- `init` is `wasm-bindgen`'s `--target web` loader. It fetches the `.wasm` and instantiates it; pass the object form
  (`{ module_or_path }`), the bare form still works but logs a deprecation warning. Calling it twice is harmless.
- A page whose Content-Security-Policy has a `script-src` must allow `'wasm-unsafe-eval'` for the WebAssembly module to
  compile. Checked in Chrome 157.0.8103.79 (`node site/tools/bench-structure.mjs --csp-check`): with
  `script-src 'self'` and no `'wasm-unsafe-eval'` instantiation is refused ("Compiling or instantiating WebAssembly module
  violates the following Content Security policy directive because 'unsafe-eval' ..."); with `script-src 'self'
  'wasm-unsafe-eval'` it works. `connect-src` must allow the URL the `.wasm` is fetched from. The
  module has exactly three imports: `Error`, a handle-drop function, and `crypto.getRandomValues`. The `getRandomValues` import
  comes from lopdf's `getrandom` dependency (`crates/pagetriage-core/Cargo.toml` enables its `wasm_js` backend so that it compiles);
  one call was observed over the eight sample PDFs in Node, and the reports do not depend on it (the determinism gate shows them
  byte-identical to the native and Python builds). The glue code makes one network request, the `.wasm` fetch in `init`, and reads
  neither clock, storage nor DOM.
- `wasm.memory` (the returned `InitOutput`) is the module's linear memory. `wasm.memory.buffer.byteLength` is its size in
  bytes; it only grows, so reading it after the call gives that worker's peak. That is the number to report as WASM memory.
- Run it in a Web Worker, as the measurements below do. The call is synchronous and blocks its thread for as long as it runs
  (about 88 ms for 300 pages here, 27 ms for the decompression bomb, 1 ms or less for a one-page file). A page that must stay
  responsive, or must stop a runaway call with `Worker.terminate()`, needs the worker.

The exports of this build (only the first is needed by dockit):

<!-- wasm-api:exports:start -->
```text
analyse_pdf_structure   the call described here (needs the pdf feature)
structure_schema_json   JSON Schema of the structure report, to validate it on the JS side
version                 crate version, to show which build was loaded
analyse_page            pixel analysis of one rendered page (not used by dockit)
finish_document         document-level pass over page reports (not used by dockit)
```
<!-- wasm-api:exports:end -->

## `analyse_pdf_structure(bytes, opts_json?) -> string`

- `bytes`: `Uint8Array`, the whole file. It must hold `%PDF-` within its first 1,024 bytes.
- `opts_json`: optional string. `undefined`, `null`, `""` and `"{}"` mean the defaults. The only key is `params`, a TOML
  string merged over the built-in structural parameters; any other key is an error. dockit passes nothing.
- Returns the canonical JSON of a `StructureReport` (schema id `pagetriage-structure/0.1`,
  `schema/pagetriage-structure-0.1.schema.json`; also `structure_schema_json()`). Keys are sorted, floats are rounded to 6
  decimals; the same input gives the same bytes on every platform and in the native and Python builds.

### What throws

The call throws a JavaScript `Error` (never returns an error value). The messages below were produced by this build; the words before the
first colon name the class (`invalid input`, `invalid options`, `invalid params`). Match on that prefix, not on the whole text.

| Input | Message |
|---|---|
| Empty, or no `%PDF-` in the first 1,024 bytes (a PNG, a text file) | `invalid input: not a PDF: no %PDF- header` |
| Has the header but cannot be parsed (truncated, no readable cross-reference data) | `invalid input: cannot read PDF: failed parsing cross reference table` (the part after `cannot read PDF:` is the parser's own message) |
| The parser panicked on the input (caught, turned into an error) | `invalid input: cannot read PDF: the PDF parser panicked on this input` |
| Larger than `max_input_bytes` | `invalid input: PDF is <n> bytes; the limit is <limit>` |
| More than `max_objects` objects | `invalid input: PDF has <n> objects; the limit is <limit>` |
| `opts_json` is not valid JSON, or has an unknown key | `invalid options: ...` |
| The `params` TOML does not parse or fails validation | `invalid params: ...` |

Everything else is a report, not a throw. A file that parses but cannot be fully analysed (encrypted with a password the empty
password does not open, a damaged cross-reference table that was repaired, a page tree cut short, a content stream over the
decompression limit, a content budget used up) gives a report with `degraded: true`, a `warnings` list and, per page, `notes`.

## Limits

The input is untrusted. The limits live in `crates/pagetriage-core/params/structural_limits.toml`; the block below is checked
against that file by `tests/scripts/wasm-api-doc.sh`, so it cannot drift. All are engineering limits, not tuned on data.

<!-- wasm-api:limits:start -->
```toml
max_input_bytes = 1073741824
max_decompressed_bytes = 67108864
max_objects = 3000000
max_pages = 100000
max_content_bytes_per_page = 67108864
max_content_bytes_total = 68719476736
```
<!-- wasm-api:limits:end -->

| Limit | Value | What happens when it is reached |
|---|---|---|
| `max_input_bytes` | 1 GiB | The call throws `invalid input: PDF is <n> bytes; the limit is <limit>` before anything is parsed (`structural/pdf/mod.rs`, `analyse`). |
| `max_decompressed_bytes` | 64 MiB per stream | The inflate is bounded: it reads at most the limit plus one byte, then fails with `DecompressError::MemoryLimitExceeded` (lopdf 0.46, `Stream::decompressed_content_with_limit`, `Read::take(reader, max + 1)`). For a page content stream the page is marked `features.truncated`, a note `a content stream exceeds the decompression limit` is added and the report is `degraded`. A form XObject that cannot be decoded (over the limit included) is skipped with the note `a form XObject could not be decoded`. A `ToUnicode` map over the limit is ignored. An object stream or cross-reference stream over the limit is not decoded at load (the loader is non-strict, `LoadOptions::default()`), so the objects inside it are missing from the document. |
| `max_objects` | 3,000,000 | The call throws `invalid input: PDF has <n> objects; the limit is <limit>` after loading. |
| `max_pages` | 100,000 | Later pages are left out, a warning is added and the report is `degraded`. |
| `max_content_bytes_per_page` | 64 MiB | The page is cut short (`features.truncated`, a note) and the report is `degraded`. |
| `max_content_bytes_total` | 64 GiB | A work bound, not memory (pages are decoded one at a time). When used up, later pages are reported without a text-layer verdict and a warning is added. |

The file also bounds the page-tree depth, form XObject nesting and count, operators, operands, graphics-state depth, fonts and
images per page; hitting one gives a note and `degraded: true`.

### A stream that inflates to more than 1 GiB

It is capped, not refused: the call returns, with the page's `features.truncated` true and the report `degraded`. The cap is the
64 MiB per-stream limit above, so at most about 64 MiB of that stream is ever held (plus the copies the parser makes). Measured
here with a generated PDF whose one content stream is Flate data of about 1.07 MiB that inflates to 1,153,433,600 bytes (1.07 GiB):
the call returned in 26.60 ms (median of 5; worst 64.60 ms, the cold first call), the report had one page with
`features.truncated: true` and `degraded: true`, and the worker's WASM memory grew to
139 MiB (`wasm.memory.buffer.byteLength`; linear memory is never given back, so a worker that has seen
a bomb should be terminated and not reused). The generator is `site/tools/bench-structure.mjs`. A stream over the limit inside an
object stream is capped the same way at load time, with the consequence in the table above; no fixture for that case was measured.
dockit's Sprint 5 plan adds its own bounds before it calls this (20 MiB, 300 pages, a 60 s worker timeout with `terminate()`); the
core limits above are the second line.

## Fields dockit reads

dockit reads only the fields below (paths into the parsed report; `[]` means every element). `index` is 0-based. A path marked
`nullable` can be `null`, and the reader must handle that: `pages[].text_layer` is `null` for a page that could not be analysed
(see its `notes`), and `pages[].script` is `null` when the page has no analysable text. The block is checked against the schema by
`tests/scripts/wasm-api-doc.sh`: a documented field that leaves `schema/pagetriage-structure-0.1.schema.json` fails the test.

<!-- wasm-api:fields:start -->
```text
degraded
warnings
document.pages
structure.encrypted
structure.page_states
pages[].index
pages[].notes
pages[].text_layer nullable
pages[].text_layer.state
pages[].text_layer.confidence
pages[].text_layer.reliable nullable
pages[].script nullable
pages[].script.dominant
pages[].script.legacy_encoded
pages[].script.letters
pages[].script.shares
pages[].features nullable
pages[].features.truncated
pages[].features.outlined_text_suspected
```
<!-- wasm-api:fields:end -->

- `degraded` (boolean): part of the analysis was skipped. It does not mean the file is unusable: a damaged-xref repair and a
  single truncated page both set it. `warnings` says why.
- `structure.encrypted` (boolean): the file is encrypted. If the empty password opened it the analysis ran normally (with a
  warning); if not, `degraded` is true and the pages are not analysed. For `site/samples/pdf/encrypted.pdf` the report has
  `structure.encrypted: true`, `degraded: true` and `pages: []`; whether a locked file lists its pages with `text_layer: null`
  or none at all depends on whether the page tree can be read without the key. A caller should refuse on `structure.encrypted &&
  degraded`, never try to answer the password prompt.
- `document.pages` is the number of pages listed in `pages`.
- `pages[].text_layer.state` is one of the values in the next section. `confidence` is in [0, 1].
- `pages[].text_layer.reliable` is `false` when the layer is legacy-encoded or garbled (module M2): the characters a text
  extractor would return for that page are not the characters a reader sees (for example a legacy Devanagari font that maps glyph
  codes to Latin letters). `null` or `true` means no problem was found. Do not index the text of an unreliable page as it
  stands.
- `pages[].script.dominant` is the dominant script (`latin`, `devanagari`, ...), `none` when the page has no decodable letters,
  `unknown` when text exists but cannot be decoded. `legacy_encoded` is true for the legacy-font case; `shares` maps script to
  its share of decoded letters, `letters` is the count behind it.
- `pages[].features.truncated` is true when a limit cut the page's content short: the page's counts are lower bounds.
  `outlined_text_suspected` marks text converted to curves (a `vector_only` page that is probably a page of text: it needs OCR).
- The schema sets `additionalProperties: false` on every object, so a consumer can validate a report against
  `structure_schema_json()` and treat a field it does not know as an error.

## Text-layer states and what each means for a text extractor

<!-- wasm-api:states:start -->
```text
native_text
mixed
invisible_ocr_under_image
raster_only
vector_only
empty
```
<!-- wasm-api:states:end -->

The list is checked against the schema's `text_layer.state` enum in both directions.

| State | What the page holds | Text a PDF text extractor can read | Reference routing for Sprint 5 (TD-32: text-layer PDFs only; OCR not yet) |
|---|---|---|---|
| `native_text` | Visible text, no substantial image | Yes | Extract, unless `reliable` is `false` |
| `mixed` | Visible text together with an image of at least 1% of the page, or part of the text hidden | The visible text; nothing from the images | Extract the visible text, unless `reliable` is `false`; whatever is inside the images is not read |
| `invisible_ocr_under_image` | A text layer that is not shown (render mode 3, or under an opaque image) over a page-covering image: another tool's OCR output | Yes, as that tool wrote it; its accuracy is unknown to pagetriage | The layer exists, so it can be read without OCR here; whether to trust it is a product choice for dockit, and `reliable` says only whether it decodes |
| `raster_only` | Images cover the page, no text | No | No text layer: refuse with "OCR is not yet supported" |
| `vector_only` | Painted paths, no text, no image (`outlined_text_suspected` marks text turned into curves) | No | No text layer: refuse; with `outlined_text_suspected` the page probably holds text that needs OCR |
| `empty` | Nothing visible | No | Nothing to read: skip the page |

The last column is a reference reading of the Sprint 5 decision, so a reader of this page can see how the states are meant to be
used; the policy and its code belong to dockit, and its documentation is authoritative where the two differ.

## Measured size and timing

Machine Apple M5 Pro 48 GB (darwin 27.2.0 arm64, 18 cores), Chrome 157.0.8103.79 (installed Chrome, headless, driven by Playwright with `channel: "chrome"`),
b290cc84c08d-dirty (5 runs per row, the build is the WASM file with SHA-256 starting `30acd658b664`). **Not measured on 8 GB.** Median and
worst of 5 `analyse_pdf_structure` calls in one fresh worker, timed with `performance.now()` inside the worker (resolution about
0.1 ms in Chrome). The worst is almost always the first call. That is consistent with Chrome compiling WebAssembly functions lazily on first use
(`init` below is only about 3 ms for a 2.3 MB module, and the first call on a one-page file costs 7 to 10 ms against 1 ms or less
afterwards), but the cause was not isolated here. `init` is a fresh worker fetching, compiling and instantiating the module. The `WASM memory` column is `memory.buffer.byteLength` after the 5 calls (it never shrinks).

| Item | Value |
|---|---|
| `pagetriage_bg.wasm`, raw | 2,335,481 bytes |
| `pagetriage_bg.wasm`, `gzip -9` | 854,940 bytes |
| `init` (median / worst of 5) | 3.30 ms / 3.90 ms |

| Input | Bytes | Pages | Median ms | Worst ms | WASM memory |
|---|---|---|---|---|---|
| `sample-encrypted.pdf` | 1,536 | 0 | 0.70 | 7.10 | 1.6 MiB |
| `sample-jpeg_scan.pdf` | 1,460 | 2 | 0.80 | 8.40 | 1.6 MiB |
| `sample-native_latin.pdf` | 1,012 | 1 | 0.70 | 9.00 | 1.6 MiB |
| `sample-redacted_text.pdf` | 1,034 | 1 | 0.70 | 8.50 | 1.6 MiB |
| `sample-scanned_ocr.pdf` | 2,610 | 3 | 1.00 | 9.00 | 1.6 MiB |
| `sample-scripts_legacy.pdf` | 2,783 | 4 | 0.90 | 9.50 | 1.6 MiB |
| `sample-signed_then_edited.pdf` | 1,663 | 1 | 0.80 | 8.90 | 1.6 MiB |
| `sample-vector_empty_mixed.pdf` | 35,734 | 4 | 1.00 | 9.80 | 1.7 MiB |
| `text-20p.pdf` | 107,152 | 20 | 7.40 | 24.70 | 2.0 MiB |
| `text-100p.pdf` | 534,395 | 100 | 32.20 | 73.60 | 4.6 MiB |
| `text-300p.pdf` | 1,602,126 | 300 | 88.40 | 190.40 | 9.8 MiB |
| `bomb-content-1p.pdf` | 1,121,559 | 1 | 26.60 | 64.60 | 138.7 MiB |

The 8 files named `sample-*` are the demo's synthetic PDFs (`site/samples/pdf`). `text-20p`, `text-100p` and `text-300p` are generated,
seeded, synthetic text PDFs (52 lines of common English words per page, no real text), 300 being the page cap dockit applies. The
whole table, with the machine, command and commit on every row, is in `docs/benchmarks/wasm-structure.csv`. The numbers quoted in this
page are checked against that file by `tests/scripts/wasm-api-doc.sh`:

<!-- wasm-api:bench:start -->
```text
wasm_raw_bytes 2335481
wasm_gzip9_bytes 854940
init 3.30 3.90
sample-encrypted.pdf 0.70 7.10
sample-jpeg_scan.pdf 0.80 8.40
sample-native_latin.pdf 0.70 9.00
sample-redacted_text.pdf 0.70 8.50
sample-scanned_ocr.pdf 1.00 9.00
sample-scripts_legacy.pdf 0.90 9.50
sample-signed_then_edited.pdf 0.80 8.90
sample-vector_empty_mixed.pdf 1.00 9.80
text-20p.pdf 7.40 24.70
text-100p.pdf 32.20 73.60
text-300p.pdf 88.40 190.40
bomb-content-1p.pdf 26.60 64.60
```
<!-- wasm-api:bench:end -->

To reproduce (Chrome installed; Playwright is not a dependency of this repository, install it in a scratch directory):

```sh
PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm bash scripts/build-wasm.sh
mkdir -p /tmp/bench-deps && (cd /tmp/bench-deps && npm init -y >/dev/null && npm i --ignore-scripts playwright@1.65.0)
PLAYWRIGHT_MODULE=/tmp/bench-deps/node_modules/playwright \
  node site/tools/bench-structure.mjs --wasm dist/wasm/web --out docs/benchmarks/wasm-structure.csv
```

## Limitations

- Not measured on an 8 GB Windows laptop with Wi-Fi off, or on any machine other than the one named above. The figures are
  for a 48 GB Apple-silicon Mac; do not read them as a prediction for the target laptop.
- The call reads a PDF's structure. It does not read the text (dockit extracts that with pdf.js on the pages this call routes
  to extraction), does no OCR and has no opinion on whether text is correct, only on whether the file holds a text layer and whether
  that layer decodes.
- Test inputs are the demo's 8 synthetic PDFs and generated PDFs. No real documents were used; behaviour on real-world PDFs from
  scanners, banks or courts is not measured here.
- The timings are of the WASM build in Chrome. Firefox and Safari were not measured.
- The decompression-bomb row covers a content stream. An over-limit object stream is capped by the same limit at load time, with
  the consequence described in the limits table; no fixture for that case was run.
- `analyse_pdf_structure` is synchronous. Without a worker it blocks the page.
- Timing resolution in Chrome workers is about 0.1 ms, so the sub-millisecond rows are good to roughly that.
- The module calls `crypto.getRandomValues` (one call over the eight samples), through a dependency. Output does not depend on it,
  but the page is not strictly free of randomness requests.
