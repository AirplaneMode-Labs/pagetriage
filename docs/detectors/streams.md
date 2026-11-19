# Stream accounting (`account_pdf_streams`, S1-107)

Status: Sprint 6 (19 Nov 2026), module rule 4 page. **Working:** the call counts what every stream object of a PDF decodes to
(fonts, images, forms, content, everything else), bounded, and gives a verdict before a renderer opens the file, so a font or
image bomb is refused with a reason. It runs on native, Python and WebAssembly with byte-identical reports
(`scripts/determinism.sh`). **Not yet:** nothing here is measured on an 8 GB laptop (**not measured on 8 GB**); inline images,
Type 3 procedures and font-parsing CPU cost inside pdf.js are listed below as what the call does not bound; nothing is tagged or
published.

## Why it exists

dockit (the offline question-answering app) passes an uploaded PDF to pdf.js. A 1 MB file can hold a font or an image that
inflates to 1 GiB. `analyse_pdf_structure` already caps one content stream (64 MiB, `structural_limits.toml`); nothing bounded a
font, an image or the sum. This call does, and dockit calls it first (TD-85): a refusal, a thrown error, a trap or an
`unaccounted` report all end in the same plain refusal before pdf.js starts.

It is a separate call with its own schema (`pagetriage.streams/0.1`, TD-70), so the reports of `analyse_pdf_structure` and every
golden for old inputs are byte for byte what they were: `git diff tests/golden/pdf_expected tests/golden/expected` is empty.

## The call

```text
Rust    pagetriage_core::structural::account_pdf_streams(bytes, opts_json: Option<&str>) -> Result<String>
WASM    account_pdf_streams(bytes: &[u8], opts_json: Option<String>) -> Result<String, JsError>      (pdf feature)
Python  pagetriage_py.account_pdf_streams(data: bytes, opts: str | None = None) -> str
CLI     pagetriage streams <pdf> [--params <toml>] [--pretty]
```

All four return the canonical JSON of one report (keys sorted, compact). A document the call cannot vouch for (not a PDF,
damaged, encrypted, a stream it cannot count) is **not an error**: it is a report with `verdict: "refuse"` and
`reason: "unaccounted"`. An error is returned only for bad options (unknown JSON key, a TOML key that is not one of the seven
limits, a value that is not a positive integer). The CLI prints the report either way, then exits 0 for `ok` and 1 for a refusal,
with `error: <file> refused: <reason>` on stderr: the same convention as every other refusal of the tool.

`opts_json` is `None`, `""`, `{}` or `{"params": "<TOML>"}`. The TOML may name the seven limits below and **can only lower
them**: `min(option, default)`. A larger value is ignored, and a test proves it (`an_option_cannot_raise_a_limit`). dockit always
passes `None`.

## Output

```text
schema    "pagetriage.streams/0.1"
verdict   "ok" | "refuse"
reason    "" | one of the reasons below
limits    the seven limits in force
streams   count, by_kind {font, image, form, content, other: count, raw_bytes, decoded_bytes, max_decoded_bytes, over_limit},
          total_decoded_bytes, decoded_capped, early_stop
notes     fixed sentences; numbers only, never bytes taken from the document
```

The JSON Schema is generated from the Rust types and checked in (`schema/pagetriage-streams-0.1.schema.json`, also
`streams_schema_json()`); every golden report validates against it. `decoded_bytes` of the stream that stopped a count is its cap
plus one, so a figure with `decoded_capped: true` is a lower bound. `streams.count` is the number of stream objects found; past
`streams_max` it is `streams_max + 1` and the rest are not read.

## Limits

The values live in `crates/pagetriage-core/params/stream_limits.toml`, each with its source on the line; the block below is
checked against that file by `tests/scripts/streams-doc.sh`. All are engineering limits chosen by the architect on 19 Nov 2026,
not tuned on data. The file also holds limits of the accounting itself (a 16 MiB cap on the object streams the parser decodes
while loading, at most 8 filters per stream, dictionary size, depth and node caps) that are not options.

<!-- streams:limits:start -->
```toml
font_decoded_max = 33554432
image_decoded_max = 268435456
image_raster_max = 268435456
content_decoded_max = 67108864
other_decoded_max = 67108864
total_decoded_max = 536870912
streams_max = 3000000
```
<!-- streams:limits:end -->

| Limit | Value | Applies to |
|---|---|---|
| `font_decoded_max` | 32 MiB | One font program (`FontFile`, `FontFile2`, `FontFile3`), decoded. |
| `image_decoded_max` | 256 MiB | One image XObject, decoded. DCT, JPX, JBIG2 and CCITT data is counted as stored. |
| `image_raster_max` | 256 MiB | The raster pdf.js allocates for one image: the larger of the declared width x height and the size the JPEG or JPEG 2000 header states, times 4 bytes (RGBA). Computed without overflow. |
| `content_decoded_max` | 64 MiB | One page content stream or form XObject, decoded. |
| `other_decoded_max` | 64 MiB | Everything else: colour profiles, CMaps, object streams, shading and function streams, unreferenced objects. |
| `total_decoded_max` | 512 MiB | All streams together. Decoding stops the moment the running total passes it. |
| `streams_max` | 3,000,000 | Stream objects counted; equal to `max_objects` of the structural layer. |

## What it counts, and how

1. **Load.** The document is loaded with `lopdf` with every stream except object streams dropped as it is read, so the load
   holds the objects pages and fonts are made of and not the streams. A document that does not load, that needed its
   cross-reference data repaired, or that is encrypted is `unaccounted`. (Encrypted files are refused because the stored bytes
   are ciphertext and cannot be counted; an owner-password-only file that pdf.js opens is therefore refused too. That is the
   trade of TD-85: safety before availability.)
2. **Scan.** An own scan walks the file for every `N G obj << ... >> stream ... endstream`: unreferenced objects, every
   incremental revision and every object the parser lost. Stream data is stepped over, not searched, so text inside one stream
   cannot hide another. Anything that looks like a stream and cannot be read is `unaccounted`, never skipped. Raw size is the
   `/Length` when it agrees with the `endstream` scan, otherwise the larger of the two (a reader decodes the scanned range).
3. **Cross-check.** Every stream the parser holds must be a stream the scan found at the offset the cross-reference table gives
   it. A stream hidden in another stream's data that the table points at, or inside an object stream, is `unaccounted`
   (`an_object_hidden_inside_another_streams_data_is_unaccounted`).
4. **Plan.** Each stream gets a kind, in object-id order: font (referred to by a font descriptor, or marked `/Length1`..`/Length3`
   or a font `/Subtype`), image, form, content (a page's `/Contents`) or other. Names are read as a reader reads them: `#xx`
   escapes decoded, `Fl`/`AHx`/`A85`/`LZW`/`RL`/`CCF`/`DCT` accepted. A stream dictionary with `/F` or `/DP` is `unaccounted`
   (pdf.js reads them as short forms of `/Filter` and `/DecodeParms`, other readers as a file specification), as is an unknown
   filter, `BrotliDecode` (pdf.js supports it; counting it would need `brotli-decompressor`, already in the tree through
   lopdf, made direct: **a dependency row for the architect, not taken in Sprint 6**), more than 8 filters, or a predictor that
   does not end the chain.
5. **Count.** Streams are decoded in that order through counting decoders (`structural/pdf/decode_count.rs`) into one fixed 64 KiB
   scratch buffer: **no decoded stream is ever held**, so memory does not grow with what a stream decodes to (a growing buffer
   would also grow WebAssembly memory for good). Every stage of a chain is capped at its bound plus one byte. Flate is
   `flate2` (its `miniz_oxide` backend) and LZW is `weezl`, both already in `Cargo.lock` through lopdf (TD-86, below);
   ASCIIHex, ASCII85 and RunLength are written in the crate; a PNG or TIFF predictor is arithmetic on the count. The first stream
   over its kind's limit, or the one that takes the total over, ends the work: later streams are counted but not decoded
   (`early_stop`). The work is therefore bounded by `total_decoded_max` plus one per-stream cap whatever the number of streams.
   A decode error ends that stream's count (a reader gets the same bytes); it is not a refusal.

## Reasons and their order

<!-- streams:reasons:start -->
```text
unaccounted        the structure cannot be vouched for (checked first)
font_over_limit    a font program decodes to more than font_decoded_max
image_over_limit   an image decodes, or would be rastered, to more than its limits
content_over_limit a content stream or form decodes to more than content_decoded_max
other_over_limit   any other stream decodes to more than other_decoded_max
total_over_limit   the running total passed total_decoded_max
too_many_streams   more than streams_max stream objects (lowest priority)
```
<!-- streams:reasons:end -->

`unaccounted` first; then the first over-limit stream, or the cumulative total, in object-id order; then `too_many_streams`
(a file that exceeds it still has its first `streams_max + 1` streams decoded, so a bomb among them is reported as the bomb).
The order is the same on every platform: the scan is by file position and the decode is by `(object number, generation, offset)`.

## Gallery of synthetic bombs

Every bomb is generated at run time (`tests/support/bombs.rs`; a 1 GiB bomb is about 1 MB of deflate data, built from one
sync-flushed segment of zeros repeated) and none is committed. Seven tiny seeds, each under 100 KB, are committed with their
reports (`tests/golden/streams_inputs`, `tests/golden/streams`). `scripts/stream-bombs.sh` runs the release CLI on the whole
set under `/usr/bin/time` and `bench/streams_wasm_chrome.mjs` runs the WASM build on it in installed Chrome, 5 runs per file and a
fresh page (a fresh WebAssembly memory) per file. The budget for both is **peak memory at most input size + 64 MiB**.

| Bomb | What it is | Reason |
|---|---|---|
| `font-1gib.pdf` | FontFile2, Flate, inflates to 1 GiB | `font_over_limit` |
| `image-1gib.pdf` | image XObject, Flate, 1 GiB | `image_over_limit` |
| `content-65mib.pdf` | page content, Flate, 65 MiB (cap 64) | `content_over_limit` |
| `unreferenced-1gib.pdf` | a stream nothing refers to, 1 GiB | `other_over_limit` |
| `objstm-1gib.pdf` | an object stream inflating to 1 GiB | `other_over_limit` |
| `lying-length-1gib.pdf` | `/Length 5` on a 1 GiB bomb | `other_over_limit` |
| `asciihex-flate-1gib.pdf` | ASCIIHex wrapping a Flate bomb | `content_over_limit` |
| `flate-in-flate-1gib.pdf` | Flate inside Flate (each stage bounded) | `content_over_limit` |
| `lzw-70mib.pdf` | LZW, 70 MiB (cap 64) | `content_over_limit` |
| `jpeg-sof-65000.pdf` | declared 10 x 10, the JPEG header says 65000 x 65000 | `image_over_limit` |
| `raster-declared-100000.pdf` | 16 bytes of data, declared 100000 x 100000 | `image_over_limit` |
| `streams-100k-x-1mib.pdf` | 100,000 streams of 1 MiB each (114 MB file) | `total_over_limit`, stops in the 512th 1 MiB stream |
| `streams-100k-empty.pdf` | 100,000 empty streams | `ok` (and `too_many_streams` under `streams_max = 1000`) |
| `xref-broken-with-bomb.pdf` | a font bomb in a file that needs repair | `unaccounted` (outranks the bomb) |
| `clean.pdf` | one page, one font | `ok` |

Peak memory, native (release CLI, `/usr/bin/time -l`, `docs/benchmarks/streams-native.csv`) and WASM (`memory.buffer.byteLength`
after 5 runs in Chrome 157.0.8103.79, `docs/benchmarks/wasm-streams.csv`), in bytes, on Apple M5 Pro 48 GB, 18 cores. Every row is
within its budget. **Not measured on 8 GB.** The block is checked against the two CSV files by `tests/scripts/streams-doc.sh`:
`file reason native_peak_rss_bytes wasm_memory_after_bytes`.

<!-- streams:bench:start -->
```text
clean.pdf - 3932160 1835008
font-1gib.pdf font_over_limit 6176768 3866624
image-1gib.pdf image_over_limit 6209536 3866624
content-65mib.pdf content_over_limit 4243456 1900544
unreferenced-1gib.pdf other_over_limit 6176768 3866624
objstm-1gib.pdf other_over_limit 23216128 35848192
lying-length-1gib.pdf other_over_limit 6176768 3866624
asciihex-flate-1gib.pdf content_over_limit 8454144 5963776
flate-in-flate-1gib.pdf content_over_limit 4276224 1900544
lzw-70mib.pdf content_over_limit 4227072 1835008
jpeg-sof-65000.pdf image_over_limit 3997696 1835008
raster-declared-100000.pdf image_over_limit 3981312 1835008
streams-100k-x-1mib.pdf total_over_limit 159727616 140509184
streams-100k-empty.pdf - 52854784 33095680
xref-broken-with-bomb.pdf unaccounted 4079616 1900544
```
<!-- streams:bench:end -->

Reading the numbers:

- **Every 1 GiB bomb ends with 4 to 9 MB of native memory and 2 to 6 MB of WebAssembly memory**, against a budget of input +
  64 MiB, and in 10 to 25 ms native (median 11 to 90 ms in Chrome; the image bomb takes longest because its cap is 256 MiB).
  The WebAssembly module's initial memory is 1.6 MB (`wasm_memory_before_bytes`).
- **The object stream bomb is the largest single-stream figure** (23 MB native, 36 MB WASM): the parser decodes object streams
  itself while loading, capped at 16 MiB (`load_decoded_max`), so up to 16 MiB plus the allocator's growth is held for a moment.
- **The 100,000-stream files show the cost of the object table**, not of any stream: about 0.45 KB per object (52.9 MB native for
  100,000 objects in a 7.4 MB file; 33 MB in WASM). The "input + 64 MiB" bound holds for both 100k files, but it does not
  hold in general for a file with millions of tiny objects: the parser's object table scales with the object count (the cap is
  `max_objects`, 3,000,000, shared with the structural layer). This is the same exposure `analyse_pdf_structure` has; it is
  listed in the limitations, not hidden.
- **100,000 streams of 1 MiB each stop in the 512th stream** (`total_over_limit`, `early_stop: true`) in 0.18 s native and 0.45 s in
  Chrome, because the running total passes 512 MiB; the rest of the 114 MB file is counted by the scan and never decoded.

## What stays reachable inside pdf.js

The call bounds what a reader is told to decode. It does not bound everything pdf.js does with a file that passes. The block is
checked by `tests/scripts/streams-doc.sh` (the five names must be present); these are documented, not fixed, in Sprint 6:

<!-- streams:residuals:start -->
```text
- Inline images (BI/ID/EI) with filters sit inside content streams. A content stream is counted, but the images inside it are
  not: an inline image with a Flate filter decodes in the page's operator list, outside the count.
- Type 3 glyph procedures (CharProcs) are streams counted as "other" under the 64 MiB cap each; the glyph programs they hold
  (operators, nested inline images) run in the renderer.
- Shading and function streams are counted as "other" under the 64 MiB cap; a function with a large sample table is bounded
  only by that cap, not by what the renderer builds from it.
- pdf.js font-parsing CPU cost is not bounded by decoded size: a 20 MiB font that is under the limit can still take seconds
  in the font parser, and a malformed font can cost more than its size suggests.
- Cross-reference reconstruction differs between readers: the call refuses a document that needed repair (lopdf's repair),
  but pdf.js has its own recovery and can read a file this call would have refused, or read objects at offsets the table
  does not give; the cross-check in step 3 narrows that gap, it does not close it.
```
<!-- streams:residuals:end -->

Also known, and visible in the report as `unaccounted`: encrypted files, `BrotliDecode`, `/F` and `/DP` keys in stream
dictionaries, a predictor that does not end its chain, and any file lopdf cannot load. A PDF that pdf.js can open but this call
refuses is the price of TD-85; its false-refusal rate on an openly licensed corpus is not measured (the fixed question-set PDFs
and every Sprint 5 passing input are the only tests, in dockit).

## Dependencies (TD-86)

`pagetriage-core` takes `flate2 = "=1.1.10"` and `weezl = "=0.2.1"` as direct dependencies behind the `pdf` feature, at exactly the
versions already in `Cargo.lock` (pulled in by `lopdf 0.46.0`), with the features lopdf asks for. `cargo tree -p pagetriage-core
--features pdf -e normal` and the same for `pagetriage-wasm --target wasm32-unknown-unknown` show the **same 75 and 79 packages
before and after**; `Cargo.lock` gains two dependency lines and no `[[package]]`. Both compile to `wasm32-unknown-unknown`. NOTICE
already lists both crates (lopdf's tree); `cargo deny` is unchanged. In the dev and test profiles `miniz_oxide`, `flate2` and `weezl`
are built with `opt-level = 3` (a profile setting, no package) so that the test suite, which inflates hundreds of MiB, stays fast.

## WebAssembly size and the call's memory

`pagetriage_bg.wasm` with the `pdf` feature: 2,335,481 bytes raw and 854,940 with `gzip -9` before, 2,435,212 and 889,888 after
(+99,731 raw, +34,948 gzip). The budget of `scripts/check-wasm-size.sh` is 1,000,000 bytes gzip and is not raised (110,112 bytes
spare). Calling it in a Web Worker is the same advice as for `analyse_pdf_structure`: it is synchronous.

## Limitations

- **Not measured on an 8 GB Windows laptop** with Wi-Fi off, or on any machine other than the Apple M5 Pro 48 GB named in the CSV
  files. The figures say what this code costs on that Mac; do not read them as a prediction for the target laptop.
- The call bounds decoded bytes and image rasters. It does not run pdf.js, OCR or any model, and does not judge whether a PDF is
  well formed beyond what it needs to count its streams.
- The parser's object table grows with the object count (about 0.45 KB per object measured), so a file with millions of tiny
  objects costs memory proportional to the count even though no stream is held.
- Encrypted files and `BrotliDecode` streams are refused. Counting them needs a decrypt step or a dependency decision that has not
  been made.
- Test inputs are synthetic. No real document was used; behaviour on real-world PDFs from scanners, banks or courts is not
  measured, and neither is the false-refusal rate.
- The WASM timings are Chrome only; Firefox and Safari were not measured. Windows and Linux builds of the native tests are proven
  only by the CI jobs after the owner's push.

## Reproduce

```sh
cargo test --locked -p pagetriage-core --features pdf --test streams --test streams_golden --test streams_schema
scripts/determinism.sh                                      # native, Python and WASM against tests/golden/streams
STREAMS_CSV=docs/benchmarks/streams-native.csv scripts/stream-bombs.sh
cargo run --release -p pagetriage-core --features pdf --example gen_stream_bombs -- /tmp/bombs
PAGETRIAGE_WASM_FEATURES=pdf WASM_OUT=dist/wasm-pdf bash scripts/build-wasm.sh
PLAYWRIGHT_MODULE=<an installed playwright> node bench/streams_wasm_chrome.mjs /tmp/bombs 5 --csv docs/benchmarks/wasm-streams.csv
bash tests/scripts/streams-doc.sh                           # the numbers above equal the CSV files
```

The WASM module the page loads exports, for this call:

<!-- streams:exports:start -->
```text
account_pdf_streams   the call described here (needs the pdf feature)
streams_schema_json   JSON Schema of the report, to validate it on the JS side
```
<!-- streams:exports:end -->
