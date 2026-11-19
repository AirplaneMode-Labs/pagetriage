//! Stream accounting (S1-107, TD-70): bound the fonts, images and content streams of a PDF before a
//! renderer opens it, so that a font or image bomb is refused with a reason instead of taking the
//! tab down. The rules and the limits are in `docs/detectors/streams.md` and
//! `params/stream_limits.toml`; the report is `pagetriage.streams/0.1`.
//!
//! How it works, in the order it happens:
//!
//! 1. The document is loaded with `lopdf`, with every stream except object streams dropped as it
//!    is read (the load keeps the objects pages and fonts are made of, not the streams). A document that does not
//!    load, that needed its cross-reference data repaired, or that is encrypted is `unaccounted`.
//! 2. An own scan walks the file for every `N G obj << ... >> stream ... endstream`: unreferenced
//!    objects, every incremental revision and every object the parser lost included. Stream data
//!    is stepped over, not searched, so one stream cannot hide another by text inside it. Anything
//!    that looks like a stream and cannot be read is `unaccounted`, never skipped.
//! 3. Every stream the parser holds must be one the scan found at the offset the cross-reference
//!    table gives (a stream hidden in another stream's data, or inside an object stream, is
//!    `unaccounted`).
//! 4. Each stream gets a kind (font, image, form, content, other) and a filter plan, in object-id
//!    order. A filter layout that cannot be counted under the bound is `unaccounted`.
//! 5. The streams are decoded in that order through counting decoders (`decode_count`) with the
//!    limit of their kind, and with what is left of the total. The first stream over a limit, or
//!    the one that takes the total over, ends the work: later streams are counted but not decoded.
//!
//! Nothing here keeps a decoded stream, reads the clock, the environment or the file system, or
//! iterates a hash map.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::panic::{AssertUnwindSafe, catch_unwind};

use lopdf::xref::XrefEntry;
use lopdf::{Document, LoadOptions, Object};

use super::decode_count::{self as dc, Chain, Predictor, Stage, Terminal};
use crate::structural::params::StreamLimits;
use crate::structural::types::{
    STREAMS_SCHEMA_ID, StreamsKind, StreamsLimits, StreamsReason, StreamsReport, StreamsSummary,
    StreamsVerdict,
};

// Notes are fixed sentences. They hold numbers and kind names only, never bytes of the document.
const NOTE_LOAD: &str = "the document could not be loaded by the parser";
const NOTE_REPAIR: &str = "the cross-reference data needed repair";
const NOTE_ENCRYPTED: &str = "the document is encrypted, so its streams cannot be counted";
const NOTE_NO_HEADER: &str = "no pdf header in the first 1024 bytes";
const NOTE_SCAN: &str = "a stream or its dictionary could not be read by the scan";
const NOTE_MISMATCH: &str =
    "a stream held by the parser was not found by the scan where the cross-reference table puts it";
const NOTE_FILTER: &str = "a stream uses a filter layout that cannot be counted under the bound";
const NOTE_IMAGE_HEADER: &str =
    "an image header could not be read after other filters, so its raster is unknown";
const NOTE_EARLY: &str =
    "decoding stopped at the first stream over a limit; later streams were counted but not decoded";
const NOTE_CAPPED: &str = "a decoded count stopped at its cap, so decoded figures are lower bounds";

/// Bytes at the start of a file searched for `%PDF-`, as the structural layer does.
const HEADER_WINDOW: usize = 1024;

/// What a stream is for, which decides its limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    Font,
    Image,
    Form,
    Content,
    Other,
}

impl Kind {
    const ALL: [Kind; 5] = [
        Kind::Font,
        Kind::Image,
        Kind::Form,
        Kind::Content,
        Kind::Other,
    ];

    fn name(self) -> &'static str {
        match self {
            Kind::Font => "font",
            Kind::Image => "image",
            Kind::Form => "form",
            Kind::Content => "content",
            Kind::Other => "other",
        }
    }

    fn cap(self, l: &StreamLimits) -> u64 {
        match self {
            Kind::Font => l.font_decoded_max,
            Kind::Image => l.image_decoded_max,
            Kind::Form | Kind::Content => l.content_decoded_max,
            Kind::Other => l.other_decoded_max,
        }
    }

    fn reason(self) -> StreamsReason {
        match self {
            Kind::Font => StreamsReason::FontOverLimit,
            Kind::Image => StreamsReason::ImageOverLimit,
            Kind::Form | Kind::Content => StreamsReason::ContentOverLimit,
            Kind::Other => StreamsReason::OtherOverLimit,
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------------------------

/// Account for the streams of `bytes` under `lim`. Never fails: whatever cannot be vouched for is
/// a refusal with the reason `unaccounted`.
pub fn account(bytes: &[u8], lim: &StreamLimits) -> StreamsReport {
    let mut r = Report::new(lim);
    match run(bytes, lim, &mut r) {
        Ok(()) => {}
        Err(note) => r.unaccounted(note),
    }
    r.finish()
}

fn run(bytes: &[u8], lim: &StreamLimits, r: &mut Report) -> Result<(), String> {
    if bytes.len() as u64 > lim.input_max_bytes {
        return Err(format!(
            "the input is {} bytes; the limit is {} bytes",
            bytes.len(),
            lim.input_max_bytes
        ));
    }
    let head = &bytes[..bytes.len().min(HEADER_WINDOW)];
    let base = head
        .windows(5)
        .position(|w| w == b"%PDF-")
        .ok_or_else(|| NOTE_NO_HEADER.to_owned())?;

    let (doc, dropped) = load(bytes, lim).ok_or_else(|| NOTE_LOAD.to_owned())?;
    if doc.xref_recovery.is_some() {
        return Err(NOTE_REPAIR.to_owned());
    }
    if doc.trailer.has(b"Encrypt") {
        return Err(NOTE_ENCRYPTED.to_owned());
    }

    let scan = scan_streams(bytes, &doc, lim).ok_or_else(|| NOTE_SCAN.to_owned())?;
    // Past the stream limit only a prefix of the file was read, so the parser's streams cannot all be
    // matched; the verdict is a refusal either way.
    if !scan.truncated && !matches_parser(bytes, &doc, &dropped, &scan.cands, base) {
        return Err(NOTE_MISMATCH.to_owned());
    }
    r.count = scan.cands.len() as u64;
    r.truncated = scan.truncated;

    let (fonts, contents) = referrers(&doc);
    let mut order: Vec<u32> = (0..scan.cands.len() as u32).collect();
    order.sort_by_key(|&i| {
        let c = &scan.cands[i as usize];
        (c.num, c.gen_num, c.header)
    });

    // Every plan is made before any decoding, so a layout that cannot be counted is found first.
    let ctx = Ctx {
        bytes,
        doc: &doc,
        fonts: &fonts,
        contents: &contents,
        lim,
    };
    for &i in &order {
        if plan(&ctx, &scan.cands[i as usize]).is_none() {
            return Err(NOTE_FILTER.to_owned());
        }
    }

    let mut scratch = vec![0u8; lim.scratch_bytes];
    for &i in &order {
        let c = &scan.cands[i as usize];
        let p = plan(&ctx, c).expect("planned above");
        let entry = r.kinds.entry(p.kind.name()).or_default();
        entry.count += 1;
        entry.raw_bytes = entry.raw_bytes.saturating_add(c.raw_len);
        if r.early_stop {
            continue;
        }
        if p.raster_over(lim) {
            entry.over_limit = true;
            r.violate(StreamsReason::ImageOverLimit);
            continue;
        }
        let kind_cap = p.kind.cap(lim);
        let remaining = lim.total_decoded_max.saturating_sub(r.total);
        let (bound, total_binds) = if remaining < kind_cap {
            (remaining, true)
        } else {
            (kind_cap, false)
        };
        let raw = &bytes[c.data..c.data + c.decode_len];
        let chained_header =
            !p.chain.stages.is_empty() && matches!(p.chain.terminal, Terminal::Dct | Terminal::Jpx);
        let counted = dc::count(
            raw,
            &p.chain,
            bound,
            &mut scratch,
            if chained_header {
                lim.header_scan_bytes
            } else {
                0
            },
        );
        let entry = r.kinds.entry(p.kind.name()).or_default();
        entry.decoded_bytes = entry.decoded_bytes.saturating_add(counted.decoded);
        entry.max_decoded_bytes = entry.max_decoded_bytes.max(counted.decoded);
        r.total = r.total.saturating_add(counted.decoded);
        if counted.exceeded {
            r.capped = true;
            if total_binds {
                r.violate(StreamsReason::TotalOverLimit);
            } else {
                entry.over_limit = true;
                r.violate(p.kind.reason());
            }
            continue;
        }
        if chained_header {
            let dims = match p.chain.terminal {
                Terminal::Dct => dc::jpeg_dimensions(&counted.head, lim.jpeg_segments_max)
                    .or_else(|| dc::jpeg_dimensions_lenient(&counted.head, lim.header_scan_bytes)),
                _ => dc::jpx_dimensions(&counted.head, lim.jpeg_segments_max),
            };
            match dims {
                None => {
                    r.note(NOTE_IMAGE_HEADER);
                    r.unaccounted_flag = true;
                    r.early_stop = true;
                }
                Some((w, h)) => {
                    if raster_bytes(p.declared_area.max(u128::from(w) * u128::from(h)), lim)
                        > u128::from(lim.image_raster_max)
                    {
                        let entry = r.kinds.entry(p.kind.name()).or_default();
                        entry.over_limit = true;
                        r.violate(StreamsReason::ImageOverLimit);
                    }
                }
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// The report under construction
// ---------------------------------------------------------------------------------------------

struct Report {
    limits: StreamsLimits,
    kinds: BTreeMap<&'static str, StreamsKind>,
    count: u64,
    total: u64,
    capped: bool,
    early_stop: bool,
    truncated: bool,
    violation: Option<StreamsReason>,
    unaccounted_flag: bool,
    notes: BTreeSet<String>,
}

impl Report {
    fn new(lim: &StreamLimits) -> Self {
        Report {
            limits: StreamsLimits {
                font_decoded_max: lim.font_decoded_max,
                image_decoded_max: lim.image_decoded_max,
                image_raster_max: lim.image_raster_max,
                content_decoded_max: lim.content_decoded_max,
                other_decoded_max: lim.other_decoded_max,
                total_decoded_max: lim.total_decoded_max,
                streams_max: lim.streams_max,
            },
            kinds: Kind::ALL
                .iter()
                .map(|k| (k.name(), StreamsKind::default()))
                .collect(),
            count: 0,
            total: 0,
            capped: false,
            early_stop: false,
            truncated: false,
            violation: None,
            unaccounted_flag: false,
            notes: BTreeSet::new(),
        }
    }

    fn note(&mut self, n: &str) {
        self.notes.insert(n.to_owned());
    }

    fn unaccounted(&mut self, note: String) {
        self.unaccounted_flag = true;
        self.notes.insert(note);
    }

    fn violate(&mut self, reason: StreamsReason) {
        if self.violation.is_none() {
            self.violation = Some(reason);
        }
        self.early_stop = true;
    }

    fn finish(mut self) -> StreamsReport {
        let reason = if self.unaccounted_flag {
            StreamsReason::Unaccounted
        } else if let Some(v) = self.violation {
            v
        } else if self.truncated {
            StreamsReason::TooManyStreams
        } else {
            StreamsReason::None
        };
        if self.truncated {
            let n = format!(
                "more than {} streams; only the first {} were read",
                self.limits.streams_max, self.limits.streams_max
            );
            self.notes.insert(n);
        }
        if self.early_stop && !self.unaccounted_flag {
            self.notes.insert(NOTE_EARLY.to_owned());
        }
        if self.capped {
            self.notes.insert(NOTE_CAPPED.to_owned());
        }
        StreamsReport {
            schema: STREAMS_SCHEMA_ID.to_owned(),
            verdict: if reason == StreamsReason::None {
                StreamsVerdict::Ok
            } else {
                StreamsVerdict::Refuse
            },
            reason,
            limits: self.limits,
            streams: StreamsSummary {
                count: self.count,
                by_kind: self
                    .kinds
                    .into_iter()
                    .map(|(k, v)| (k.to_owned(), v))
                    .collect(),
                total_decoded_bytes: self.total,
                decoded_capped: self.capped,
                early_stop: self.early_stop,
            },
            notes: self.notes.into_iter().collect(),
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Loading the document without keeping stream bytes
// ---------------------------------------------------------------------------------------------

thread_local! {
    /// The ids of the streams `strip` dropped while one document loaded. The parser's filter is a
    /// plain function pointer and cannot capture anything, so it reports through this.
    static DROPPED_STREAMS: RefCell<Vec<(u32, u16)>> = const { RefCell::new(Vec::new()) };
}

/// Drop each stream (dictionary and bytes) as the parser reads it, and note its id: the load keeps
/// the objects a page and a font are made of, not the streams, which are what this module counts
/// from the file itself. Object streams are kept: the parser needs them to read the objects inside.
/// Without this the parser holds about a kilobyte per stream object, and a file of 100,000 small
/// streams would cost 100 MB.
fn strip(id: (u32, u16), obj: &mut Object) -> Option<((u32, u16), Object)> {
    if let Object::Stream(s) = obj {
        let objstm = s.dict.get(b"Type").ok().and_then(|t| t.as_name().ok()) == Some(b"ObjStm");
        if !objstm {
            DROPPED_STREAMS.with(|v| v.borrow_mut().push(id));
            *obj = Object::Null;
        }
    }
    Some((id, Object::Null))
}

/// The document and the ids of the streams that were dropped as it loaded.
fn load(bytes: &[u8], lim: &StreamLimits) -> Option<(Document, Vec<(u32, u16)>)> {
    DROPPED_STREAMS.with(|v| v.borrow_mut().clear());
    let opts = LoadOptions {
        max_decompressed_size: Some(lim.load_decoded_max as usize),
        filter: Some(strip),
        ..LoadOptions::default()
    };
    let doc = catch_unwind(AssertUnwindSafe(|| {
        Document::load_mem_with_options(bytes, opts)
    }))
    .ok()
    .and_then(Result::ok);
    let dropped = DROPPED_STREAMS.with(|v| std::mem::take(&mut *v.borrow_mut()));
    doc.map(|d| (d, dropped))
}

/// Object numbers that fonts and pages refer to: font programs (`FontFile`, `FontFile2`,
/// `FontFile3`) and page content streams (`/Contents`, a stream or an array of streams).
fn referrers(doc: &Document) -> (BTreeSet<u32>, BTreeSet<u32>) {
    let mut fonts = BTreeSet::new();
    let mut contents = BTreeSet::new();
    for obj in doc.objects.values() {
        let dict = match obj {
            Object::Dictionary(d) => d,
            Object::Stream(s) => &s.dict,
            _ => continue,
        };
        for key in [b"FontFile".as_slice(), b"FontFile2", b"FontFile3"] {
            if let Ok(Object::Reference((n, _))) = dict.get(key) {
                fonts.insert(*n);
            }
        }
        if dict.get(b"Type").ok().and_then(|t| t.as_name().ok()) == Some(b"Page") {
            match dict.get(b"Contents") {
                Ok(Object::Reference(id)) => {
                    contents.insert(id.0);
                    if let Some(Object::Array(items)) = doc.objects.get(id) {
                        contents.extend(
                            items
                                .iter()
                                .filter_map(|o| o.as_reference().ok())
                                .map(|r| r.0),
                        );
                    }
                }
                Ok(Object::Array(items)) => {
                    contents.extend(
                        items
                            .iter()
                            .filter_map(|o| o.as_reference().ok())
                            .map(|r| r.0),
                    );
                }
                _ => {}
            }
        }
    }
    (fonts, contents)
}

// ---------------------------------------------------------------------------------------------
// A small object model for stream dictionaries
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Obj {
    Null,
    Bool(bool),
    /// Integers, and reals rounded up (toward zero for negatives): sizes are bounds, not values.
    Int(i64),
    Name(Vec<u8>),
    Str,
    Array(Vec<Obj>),
    Dict(BTreeMap<Vec<u8>, Obj>),
    Ref(u32, u16),
}

type Dict = BTreeMap<Vec<u8>, Obj>;

fn is_ws(c: u8) -> bool {
    matches!(c, 0 | 9 | 10 | 12 | 13 | 32)
}

fn is_delim(c: u8) -> bool {
    matches!(
        c,
        b'(' | b')' | b'<' | b'>' | b'[' | b']' | b'{' | b'}' | b'/' | b'%'
    )
}

fn hex_digit(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

struct Parser<'a> {
    b: &'a [u8],
    i: usize,
    start: usize,
    nodes: usize,
    lim: &'a StreamLimits,
}

impl Parser<'_> {
    fn ws(&mut self) {
        while let Some(&c) = self.b.get(self.i) {
            if is_ws(c) {
                self.i += 1;
            } else if c == b'%' {
                while self
                    .b
                    .get(self.i)
                    .is_some_and(|&c| c != b'\n' && c != b'\r')
                {
                    self.i += 1;
                }
            } else {
                break;
            }
        }
    }

    fn tick(&mut self) -> Option<()> {
        self.nodes += 1;
        if self.nodes > self.lim.dict_nodes_max
            || self.i.saturating_sub(self.start) > self.lim.dict_bytes_max
        {
            return None;
        }
        Some(())
    }

    fn name(&mut self) -> Option<Vec<u8>> {
        if self.b.get(self.i) != Some(&b'/') {
            return None;
        }
        self.i += 1;
        let mut out = Vec::new();
        while let Some(&c) = self.b.get(self.i) {
            if is_ws(c) || is_delim(c) {
                break;
            }
            if c == b'#'
                && let (Some(h), Some(l)) = (
                    self.b.get(self.i + 1).and_then(|&c| hex_digit(c)),
                    self.b.get(self.i + 2).and_then(|&c| hex_digit(c)),
                )
            {
                out.push(h * 16 + l);
                self.i += 3;
                continue;
            }
            out.push(c);
            self.i += 1;
        }
        Some(out)
    }

    fn number(&mut self) -> Option<Obj> {
        let mut neg = false;
        while let Some(&c) = self.b.get(self.i) {
            match c {
                b'-' => neg = true,
                b'+' => {}
                _ => break,
            }
            self.i += 1;
        }
        let mut int: i64 = 0;
        let mut digits = 0usize;
        while let Some(&c) = self.b.get(self.i).filter(|c| c.is_ascii_digit()) {
            int = int.saturating_mul(10).saturating_add(i64::from(c - b'0'));
            digits += 1;
            self.i += 1;
        }
        let mut frac_nonzero = false;
        let mut real = false;
        if self.b.get(self.i) == Some(&b'.') {
            real = true;
            self.i += 1;
            while let Some(&c) = self.b.get(self.i).filter(|c| c.is_ascii_digit()) {
                if c != b'0' {
                    frac_nonzero = true;
                }
                digits += 1;
                self.i += 1;
            }
        }
        if digits == 0 {
            return None;
        }
        if real {
            let v = if frac_nonzero && !neg {
                int.saturating_add(1)
            } else {
                int
            };
            return Some(Obj::Int(if neg { -v } else { v }));
        }
        if !neg {
            // `N G R` is a reference
            let save = self.i;
            if let Some(r) = self.reference_tail(int) {
                return Some(r);
            }
            self.i = save;
        }
        Some(Obj::Int(if neg { -int } else { int }))
    }

    fn reference_tail(&mut self, num: i64) -> Option<Obj> {
        let num = u32::try_from(num).ok()?;
        let mut j = self.i;
        let w = j;
        while self.b.get(j).is_some_and(|&c| is_ws(c)) {
            j += 1;
        }
        if j == w {
            return None;
        }
        let g = j;
        let mut gen_num: u32 = 0;
        while let Some(&c) = self.b.get(j).filter(|c| c.is_ascii_digit()) {
            gen_num = gen_num
                .saturating_mul(10)
                .saturating_add(u32::from(c - b'0'));
            j += 1;
        }
        if j == g || gen_num > 65535 {
            return None;
        }
        let w = j;
        while self.b.get(j).is_some_and(|&c| is_ws(c)) {
            j += 1;
        }
        if j == w || self.b.get(j) != Some(&b'R') {
            return None;
        }
        j += 1;
        if self.b.get(j).is_some_and(|&c| !is_ws(c) && !is_delim(c)) {
            return None;
        }
        self.i = j;
        Some(Obj::Ref(num, gen_num as u16))
    }

    fn keyword(&mut self, word: &[u8], value: Obj) -> Option<Obj> {
        if !self.b[self.i..].starts_with(word) {
            return None;
        }
        let end = self.i + word.len();
        if self.b.get(end).is_some_and(|&c| !is_ws(c) && !is_delim(c)) {
            return None;
        }
        self.i = end;
        Some(value)
    }

    fn value(&mut self, depth: usize) -> Option<Obj> {
        if depth > self.lim.dict_depth_max {
            return None;
        }
        self.ws();
        self.tick()?;
        match *self.b.get(self.i)? {
            b'/' => self.name().map(Obj::Name),
            b'(' => {
                let mut level = 0usize;
                loop {
                    match *self.b.get(self.i)? {
                        b'\\' => self.i += 2,
                        b'(' => {
                            level += 1;
                            self.i += 1;
                        }
                        b')' => {
                            level -= 1;
                            self.i += 1;
                            if level == 0 {
                                return Some(Obj::Str);
                            }
                        }
                        _ => self.i += 1,
                    }
                    self.tick()?;
                }
            }
            b'<' => {
                if self.b.get(self.i + 1) == Some(&b'<') {
                    self.dict(depth + 1).map(Obj::Dict)
                } else {
                    self.i += 1;
                    loop {
                        let c = *self.b.get(self.i)?;
                        self.i += 1;
                        if c == b'>' {
                            return Some(Obj::Str);
                        }
                        if !is_ws(c) && hex_digit(c).is_none() {
                            return None;
                        }
                    }
                }
            }
            b'[' => {
                self.i += 1;
                let mut items = Vec::new();
                loop {
                    self.ws();
                    if self.b.get(self.i) == Some(&b']') {
                        self.i += 1;
                        return Some(Obj::Array(items));
                    }
                    items.push(self.value(depth + 1)?);
                }
            }
            b't' => self.keyword(b"true", Obj::Bool(true)),
            b'f' => self.keyword(b"false", Obj::Bool(false)),
            b'n' => self.keyword(b"null", Obj::Null),
            b'+' | b'-' | b'.' | b'0'..=b'9' => self.number(),
            _ => None,
        }
    }

    fn dict(&mut self, depth: usize) -> Option<Dict> {
        if depth > self.lim.dict_depth_max || !self.b[self.i..].starts_with(b"<<") {
            return None;
        }
        self.i += 2;
        let mut map = Dict::new();
        loop {
            self.ws();
            self.tick()?;
            if self.b[self.i..].starts_with(b">>") {
                self.i += 2;
                return Some(map);
            }
            let key = self.name()?;
            let val = self.value(depth)?;
            // a repeated key: the last one wins, as in pdf.js and lopdf
            map.insert(key, val);
        }
    }
}

/// Parse the dictionary that starts at `at`; returns it and the offset just past `>>`.
fn parse_dict(b: &[u8], at: usize, lim: &StreamLimits) -> Option<(Dict, usize)> {
    let mut p = Parser {
        b,
        i: at,
        start: at,
        nodes: 0,
        lim,
    };
    let d = p.dict(0)?;
    Some((d, p.i))
}

fn from_lopdf(o: &Object, depth: usize) -> Obj {
    if depth > 8 {
        return Obj::Null;
    }
    match o {
        Object::Boolean(b) => Obj::Bool(*b),
        Object::Integer(i) => Obj::Int(*i),
        Object::Real(f) if f.is_finite() && f.abs() < 9.0e15 => {
            let c = if *f > 0.0 { f.ceil() } else { f.trunc() };
            Obj::Int(c as i64)
        }
        Object::Name(n) => Obj::Name(n.clone()),
        Object::String(..) => Obj::Str,
        Object::Array(a) => Obj::Array(a.iter().map(|x| from_lopdf(x, depth + 1)).collect()),
        Object::Dictionary(d) => Obj::Dict(
            d.iter()
                .map(|(k, v)| (k.clone(), from_lopdf(v, depth + 1)))
                .collect(),
        ),
        Object::Reference((n, g)) => Obj::Ref(*n, *g),
        _ => Obj::Null,
    }
}

/// Follow references (through the parser's objects) to a value that is not one.
fn resolve(doc: &Document, o: &Obj) -> Obj {
    let mut cur = o.clone();
    for _ in 0..4 {
        match cur {
            Obj::Ref(n, g) => match doc.objects.get(&(n, g)) {
                Some(x) => cur = from_lopdf(x, 0),
                None => return Obj::Null,
            },
            _ => return cur,
        }
    }
    Obj::Null
}

fn get(doc: &Document, d: &Dict, key: &[u8]) -> Obj {
    d.get(key).map_or(Obj::Null, |o| resolve(doc, o))
}

fn int_of(o: &Obj) -> Option<i64> {
    match o {
        Obj::Int(i) => Some(*i),
        _ => None,
    }
}

fn name_of(o: &Obj) -> Option<&[u8]> {
    match o {
        Obj::Name(n) => Some(n),
        _ => None,
    }
}

// ---------------------------------------------------------------------------------------------
// The scan
// ---------------------------------------------------------------------------------------------

/// One stream object found in the file.
struct Cand {
    num: u32,
    gen_num: u16,
    /// Offset of the object number of `N G obj`.
    header: usize,
    dict_start: usize,
    /// Where the data starts, and how many bytes of it a reader decodes.
    data: usize,
    decode_len: usize,
    /// Raw size as reported: the declared length when it agrees with the `endstream` scan, else
    /// the larger of the two.
    raw_len: u64,
}

struct Scan {
    /// In file order.
    cands: Vec<Cand>,
    truncated: bool,
}

fn find(b: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    let first = needle[0];
    let mut i = from;
    while i + needle.len() <= b.len() {
        let k = b[i..=b.len() - needle.len()]
            .iter()
            .position(|&c| c == first)?;
        let p = i + k;
        if &b[p..p + needle.len()] == needle {
            return Some(p);
        }
        i = p + 1;
    }
    None
}

struct Header {
    start: usize,
    after: usize,
    num: u32,
    gen_num: u16,
}

/// Is there an `N G obj` token whose `obj` starts at `p`?
fn header_at(b: &[u8], p: usize) -> Option<Header> {
    if b.get(p + 3).is_some_and(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    let mut i = p;
    let ws_start = i;
    while i > 0 && is_ws(b[i - 1]) {
        i -= 1;
    }
    if i == ws_start {
        return None;
    }
    let gen_end = i;
    while i > 0 && b[i - 1].is_ascii_digit() {
        i -= 1;
    }
    if i == gen_end || gen_end - i > 5 {
        return None;
    }
    let gen_num: u32 = std::str::from_utf8(&b[i..gen_end]).ok()?.parse().ok()?;
    let ws_start = i;
    while i > 0 && is_ws(b[i - 1]) {
        i -= 1;
    }
    if i == ws_start {
        return None;
    }
    let num_end = i;
    while i > 0 && b[i - 1].is_ascii_digit() {
        i -= 1;
    }
    if i == num_end || num_end - i > 10 {
        return None;
    }
    if i > 0 && !is_ws(b[i - 1]) && !is_delim(b[i - 1]) {
        return None;
    }
    let num: u32 = std::str::from_utf8(&b[i..num_end]).ok()?.parse().ok()?;
    Some(Header {
        start: i,
        after: p + 3,
        num,
        gen_num: u16::try_from(gen_num).ok()?,
    })
}

fn next_header(b: &[u8], mut from: usize) -> Option<Header> {
    while let Some(p) = find(b, b"obj", from) {
        from = p + 3;
        if let Some(h) = header_at(b, p) {
            return Some(h);
        }
    }
    None
}

fn skip_ws(b: &[u8], mut i: usize) -> usize {
    while b.get(i).is_some_and(|&c| is_ws(c)) {
        i += 1;
    }
    i
}

fn skip_ws_comments(b: &[u8], mut i: usize) -> usize {
    loop {
        i = skip_ws(b, i);
        if b.get(i) == Some(&b'%') {
            while b.get(i).is_some_and(|&c| c != b'\n' && c != b'\r') {
                i += 1;
            }
        } else {
            return i;
        }
    }
}

/// A `stream` keyword (not the end of `endstream`) followed by a line end, between `from` and `to`.
fn has_stream_keyword(b: &[u8], from: usize, to: usize) -> bool {
    let to = to.min(b.len());
    let mut i = from;
    while let Some(p) = find(&b[..to], b"stream", i) {
        let before_ok = p == 0 || !b[p - 1].is_ascii_alphanumeric();
        let after = b.get(p + 6).copied();
        if before_ok && matches!(after, Some(b'\r' | b'\n' | b' ')) {
            return true;
        }
        i = p + 6;
    }
    false
}

/// Does a reader that has taken `at - 0` bytes of stream data find `endstream` next?
fn endstream_follows(b: &[u8], at: usize) -> bool {
    let k = skip_ws(b, at.min(b.len()));
    b[k.min(b.len())..].starts_with(b"endstream")
}

fn scan_streams(b: &[u8], doc: &Document, lim: &StreamLimits) -> Option<Scan> {
    let mut cands: Vec<Cand> = Vec::new();
    let mut truncated = false;
    let mut i = 0usize;
    // A search for a keyword that found nothing from here means there is none from any later point.
    let mut no_endstream_from = usize::MAX;
    let mut no_endobj_from = usize::MAX;
    while let Some(h) = next_header(b, i) {
        i = h.after;
        let j = skip_ws_comments(b, h.after);
        if !b[j.min(b.len())..].starts_with(b"<<") {
            continue;
        }
        let Some((dict, end)) = parse_dict(b, j, lim) else {
            // Not a dictionary the scan can read. Fine unless a stream follows in this object.
            let window = b.len().min(j.saturating_add(lim.dict_bytes_max));
            let obj_end = if j >= no_endobj_from {
                window
            } else {
                match find(&b[..window], b"endobj", j) {
                    Some(p) => p,
                    None => {
                        no_endobj_from = j;
                        window
                    }
                }
            };
            if has_stream_keyword(b, j, obj_end) {
                return None;
            }
            i = j + 2;
            continue;
        };
        let k = skip_ws(b, end);
        if !b[k.min(b.len())..].starts_with(b"stream") {
            i = end;
            continue;
        }
        // the line end after `stream`: spaces, then CR, LF or CRLF
        let mut d = k + 6;
        while matches!(b.get(d), Some(b' ' | b'\t')) {
            d += 1;
        }
        match b.get(d) {
            Some(b'\r') => {
                d += 1;
                if b.get(d) == Some(&b'\n') {
                    d += 1;
                }
            }
            Some(b'\n') => d += 1,
            _ => return None,
        }

        let declared = declared_length(doc, &dict);
        let agrees = declared.and_then(|l| {
            let l = usize::try_from(l).ok()?;
            let e = d.checked_add(l)?;
            (e <= b.len() && endstream_follows(b, e)).then_some(l)
        });
        let (decode_len, raw_len, resume) = if let Some(l) = agrees {
            (l, l as u64, d + l)
        } else {
            let found = if d >= no_endstream_from {
                None
            } else {
                let f = find(b, b"endstream", d);
                if f.is_none() {
                    no_endstream_from = d;
                }
                f
            };
            match found {
                Some(p) => {
                    // the line end that precedes `endstream` is not part of the data
                    let mut e = p;
                    if e > d && b[e - 1] == b'\n' {
                        e -= 1;
                        if e > d && b[e - 1] == b'\r' {
                            e -= 1;
                        }
                    } else if e > d && b[e - 1] == b'\r' {
                        e -= 1;
                    }
                    let scanned = (e - d) as u64;
                    (e - d, scanned.max(declared.unwrap_or(0)), p + 9)
                }
                None => {
                    // no endstream at all: a reader refuses it; count to the end of the file
                    let n = b.len() - d;
                    (n, (n as u64).max(declared.unwrap_or(0)), b.len())
                }
            }
        };

        cands.push(Cand {
            num: h.num,
            gen_num: h.gen_num,
            header: h.start,
            dict_start: j,
            data: d,
            decode_len,
            raw_len,
        });
        if cands.len() as u64 > lim.streams_max {
            truncated = true;
            break;
        }
        i = resume.max(i);
    }
    Some(Scan { cands, truncated })
}

/// The `/Length` of a stream when it is a non-negative integer, directly or through a reference.
fn declared_length(doc: &Document, dict: &Dict) -> Option<u64> {
    let l = int_of(&get(doc, dict, b"Length"))?;
    u64::try_from(l).ok()
}

/// Every stream the parser holds must be a stream the scan found, at the offset the
/// cross-reference table gives it. A stream in an object stream, or text inside another stream that
/// the table points at, would be one a reader opens and the scan never saw.
fn matches_parser(
    b: &[u8],
    doc: &Document,
    dropped: &[(u32, u16)],
    cands: &[Cand],
    base: usize,
) -> bool {
    // the streams `strip` dropped, and the object streams the parser kept
    let kept = doc
        .objects
        .iter()
        .filter(|(_, o)| matches!(o, Object::Stream(_)))
        .map(|(id, _)| *id);
    for (num, _) in dropped.iter().copied().chain(kept) {
        let Some(XrefEntry::Normal { offset, .. }) = doc.reference_table.entries.get(&num) else {
            return false;
        };
        let y = skip_ws(b, base.saturating_add(*offset as usize));
        let idx = cands.partition_point(|c| c.header <= y);
        let ok = idx > 0 && {
            let c = &cands[idx - 1];
            c.num == num && y <= c.dict_start
        };
        if !ok {
            return false;
        }
    }
    true
}

// ---------------------------------------------------------------------------------------------
// Kind and decode plan of one stream
// ---------------------------------------------------------------------------------------------

struct Ctx<'a> {
    bytes: &'a [u8],
    doc: &'a Document,
    fonts: &'a BTreeSet<u32>,
    contents: &'a BTreeSet<u32>,
    lim: &'a StreamLimits,
}

struct Planned {
    kind: Kind,
    chain: Chain,
    /// Largest declared width x height, and the one stated by a JPEG or JPX header that could be
    /// read from the stored bytes.
    declared_area: u128,
    header_area: u128,
}

fn raster_bytes(area: u128, lim: &StreamLimits) -> u128 {
    area.saturating_mul(u128::from(lim.raster_bytes_per_pixel))
}

impl Planned {
    fn raster_over(&self, lim: &StreamLimits) -> bool {
        self.kind == Kind::Image
            && raster_bytes(self.declared_area.max(self.header_area), lim)
                > u128::from(lim.image_raster_max)
    }
}

fn canonical_filter(name: &[u8]) -> Option<&'static str> {
    Some(match name {
        b"FlateDecode" | b"Fl" => "flate",
        b"LZWDecode" | b"LZW" => "lzw",
        b"ASCIIHexDecode" | b"AHx" => "hex",
        b"ASCII85Decode" | b"A85" => "a85",
        b"RunLengthDecode" | b"RL" => "rl",
        b"DCTDecode" | b"DCT" => "dct",
        b"JPXDecode" | b"JPX" => "jpx",
        b"JBIG2Decode" => "jbig2",
        b"CCITTFaxDecode" | b"CCF" => "ccitt",
        // not a filter at all for counting: with no cipher transform it hands the data on unchanged
        b"Crypt" => "crypt",
        _ => return None,
    })
}

/// Plan the decode of one stream, or `None` when it cannot be counted under the bound.
fn plan(ctx: &Ctx, c: &Cand) -> Option<Planned> {
    let lim = ctx.lim;
    let (dict, _) = parse_dict(ctx.bytes, c.dict_start, lim)?;
    // pdf.js reads `/F` and `/DP` as short forms of `/Filter` and `/DecodeParms` in every stream
    // dictionary, with the short form first; `/F` is also a file specification. Readers disagree
    // about what such a stream is, so it is not counted.
    if dict.contains_key(b"F".as_slice()) || dict.contains_key(b"DP".as_slice()) {
        return None;
    }

    let filter = get(ctx.doc, &dict, b"Filter");
    let names: Vec<Obj> = match filter {
        Obj::Name(n) => vec![Obj::Name(n)],
        Obj::Array(items) => items.iter().map(|o| resolve(ctx.doc, o)).collect(),
        // a reader that does not understand the entry applies no filter
        _ => Vec::new(),
    };
    if names.len() > lim.filters_max {
        return None;
    }
    let params = get(ctx.doc, &dict, b"DecodeParms");
    let params_for = |i: usize| -> Option<Dict> {
        let p = match (&params, names.len()) {
            (Obj::Array(a), _) => a.get(i).map(|o| resolve(ctx.doc, o)),
            (p, 1) if i == 0 => Some(p.clone()),
            _ => None,
        };
        match p {
            Some(Obj::Dict(d)) => Some(d),
            _ => None,
        }
    };

    let mut stages = Vec::new();
    let mut terminal = Terminal::None;
    let mut predictor = Predictor::None;
    let mut predictor_at = None;
    for (i, n) in names.iter().enumerate() {
        let name = canonical_filter(name_of(n)?)?;
        let p = params_for(i);
        let last = i + 1 == names.len();
        match name {
            "flate" | "lzw" => {
                if name == "flate" {
                    stages.push(Stage::Flate);
                } else {
                    let early = p
                        .as_ref()
                        .and_then(|d| d.get(b"EarlyChange".as_slice()))
                        .map(|o| resolve(ctx.doc, o))
                        .and_then(|o| int_of(&o))
                        .is_none_or(|v| v != 0);
                    stages.push(Stage::Lzw {
                        early_change: early,
                    });
                }
                if let Some(d) = &p {
                    let pred = int_of(&get(ctx.doc, d, b"Predictor")).unwrap_or(1);
                    if pred > 1 {
                        predictor_at = Some(i);
                    }
                    predictor = match pred {
                        2 => Predictor::Tiff,
                        10..=15 => {
                            let field = |keys: &[&[u8]], default: i64| -> u64 {
                                keys.iter()
                                    .find_map(|k| int_of(&get(ctx.doc, d, k)))
                                    .filter(|v| *v > 0)
                                    .unwrap_or(default) as u64
                            };
                            let columns = field(&[b"Columns"], 1);
                            let colors = field(&[b"Colors"], 1);
                            let bpc = field(&[b"BPC", b"BitsPerComponent"], 8);
                            let bits = columns.saturating_mul(colors).saturating_mul(bpc);
                            Predictor::Png {
                                row_bytes: (bits.saturating_add(7) / 8).max(1),
                            }
                        }
                        // an unsupported value makes a reader fail the stream: the count before a
                        // predictor is an upper bound
                        _ => Predictor::None,
                    };
                }
            }
            "hex" => stages.push(Stage::AsciiHex),
            "a85" => stages.push(Stage::Ascii85),
            "rl" => stages.push(Stage::RunLength),
            "dct" | "jpx" | "jbig2" | "ccitt" => {
                if !last {
                    return None;
                }
                terminal = match name {
                    "dct" => Terminal::Dct,
                    "jpx" => Terminal::Jpx,
                    "jbig2" => Terminal::Jbig2,
                    _ => Terminal::Ccitt,
                };
            }
            _ => {} // crypt: passes the data on
        }
    }
    // A predictor is arithmetic on the count of the last stage; it cannot feed another filter.
    if predictor_at.is_some_and(|k| k + 1 != names.len()) {
        return None;
    }

    let subtype = get(ctx.doc, &dict, b"Subtype");
    let sub = name_of(&subtype);
    let font_marker = matches!(sub, Some(b"Type1C" | b"CIDFontType0C" | b"OpenType"))
        || [b"Length1".as_slice(), b"Length2", b"Length3"]
            .iter()
            .any(|k| dict.contains_key(*k));
    let kind = if ctx.fonts.contains(&c.num) || font_marker {
        Kind::Font
    } else if sub == Some(b"Image") {
        Kind::Image
    } else if sub == Some(b"Form") {
        Kind::Form
    } else if ctx.contents.contains(&c.num) {
        Kind::Content
    } else {
        Kind::Other
    };

    let (mut declared_area, mut header_area) = (0u128, 0u128);
    if kind == Kind::Image {
        let size = |long: &[u8], short: &[u8]| -> u128 {
            [long, short]
                .iter()
                .filter_map(|k| int_of(&get(ctx.doc, &dict, k)))
                .map(|v| v.max(0) as u128)
                .max()
                .unwrap_or(0)
        };
        declared_area = size(b"Width", b"W") * size(b"Height", b"H");
        if stages.is_empty() {
            let raw = &ctx.bytes[c.data..c.data + c.decode_len];
            let dims = match terminal {
                Terminal::Dct => dc::jpeg_dimensions(raw, lim.jpeg_segments_max)
                    .or_else(|| dc::jpeg_dimensions_lenient(raw, lim.header_scan_bytes)),
                Terminal::Jpx => dc::jpx_dimensions(raw, lim.jpeg_segments_max),
                _ => None,
            };
            if let Some((w, h)) = dims {
                header_area = u128::from(w) * u128::from(h);
            }
        }
    }
    Some(Planned {
        kind,
        chain: Chain {
            stages,
            terminal,
            predictor,
        },
        declared_area,
        header_area,
    })
}
