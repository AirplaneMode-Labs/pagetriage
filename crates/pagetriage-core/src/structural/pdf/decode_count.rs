//! Counting decoders for the stream accounting (S1-107, TD-70).
//!
//! A stream's filter chain is run as a pipeline of `Read` adaptors over the stored bytes, and the
//! last one is drained through one fixed scratch buffer that only counts. The decoded bytes are
//! never collected, so the memory of the accounting does not grow with what a stream decodes to
//! (a growing `Vec` would also grow WebAssembly memory for good: it is never given back).
//!
//! Every stage's output is capped at one byte past the bound, so a stage that produces more than
//! the bound is stopped by its consumer instead of running on. Flate comes from `flate2` (its
//! `miniz_oxide` backend) and LZW from `weezl`, both already in the dependency tree through
//! `lopdf` (TD-86); ASCIIHex, ASCII85 and RunLength are written here. A predictor is only
//! arithmetic on the count: it never needs the bytes. DCT, JPX, JBIG2 and CCITT data is counted as
//! stored, and for DCT and JPX the header says how large a raster the image will be.

use std::cell::Cell;
use std::io::{self, Read};

/// A filter that is run to count its output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    AsciiHex,
    Ascii85,
    RunLength,
    Flate,
    Lzw { early_change: bool },
}

/// An image codec that ends a chain. It is not run: its input is counted as stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Terminal {
    None,
    Dct,
    Jpx,
    Jbig2,
    Ccitt,
}

/// The predictor of a Flate or LZW stage that ends the chain. It changes the count only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Predictor {
    None,
    /// TIFF predictor 2: same size in and out.
    Tiff,
    /// PNG predictors 10 to 15: each row has one tag byte more than `row_bytes`.
    Png {
        row_bytes: u64,
    },
}

/// A stream's decode plan: stages in the order they are applied, then an optional image codec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chain {
    pub stages: Vec<Stage>,
    pub terminal: Terminal,
    pub predictor: Predictor,
}

/// What counting a stream found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Counted {
    /// Bytes the chain decodes to (after a predictor); `bound + 1` when `exceeded`.
    pub decoded: u64,
    /// The count passed the bound, in the last stage or in an intermediate one.
    pub exceeded: bool,
    /// The first bytes of the last stage's output, for a header scan.
    pub head: Vec<u8>,
}

/// Count what `raw` decodes to under `chain`, stopping once the count passes `bound`.
///
/// `scratch` is the fixed buffer the count goes through. `head_max` bytes of output are kept for
/// the caller (a JPEG or JPX header after other filters); pass 0 when they are not wanted.
pub fn count(
    raw: &[u8],
    chain: &Chain,
    bound: u64,
    scratch: &mut [u8],
    head_max: usize,
) -> Counted {
    let pre_bound = match chain.predictor {
        Predictor::Png { row_bytes } => bound
            .saturating_add(bound / row_bytes.max(1))
            .saturating_add(2),
        _ => bound,
    };
    let mut head = Vec::new();
    let (pre_total, over) = if chain.stages.is_empty() {
        head.extend_from_slice(&raw[..raw.len().min(head_max)]);
        (raw.len() as u64, raw.len() as u64 > pre_bound)
    } else {
        let tripped = Cell::new(false);
        let mut reader: Box<dyn Read + '_> = Box::new(raw);
        for stage in &chain.stages {
            reader = stage_reader(*stage, reader);
            reader = Box::new(Bounded {
                inner: reader,
                left: pre_bound.saturating_add(1),
                tripped: &tripped,
            });
        }
        let mut total = 0u64;
        loop {
            match reader.read(scratch) {
                // A decode error ends the count: the bytes before it are what a reader gets too.
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if head.len() < head_max {
                        let take = n.min(head_max - head.len());
                        head.extend_from_slice(&scratch[..take]);
                    }
                    total += n as u64;
                    if total > pre_bound {
                        break;
                    }
                }
            }
        }
        (total, tripped.get() || total > pre_bound)
    };
    let decoded = if over {
        u64::MAX
    } else {
        after_predictor(pre_total, chain.predictor)
    };
    if decoded > bound {
        Counted {
            decoded: bound.saturating_add(1),
            exceeded: true,
            head,
        }
    } else {
        Counted {
            decoded,
            exceeded: false,
            head,
        }
    }
}

/// The size after a predictor, from the size before it.
pub fn after_predictor(n: u64, predictor: Predictor) -> u64 {
    match predictor {
        Predictor::Png { row_bytes } if row_bytes > 0 => {
            let full = n / (row_bytes + 1);
            let rest = n % (row_bytes + 1);
            full * row_bytes + rest.saturating_sub(1)
        }
        _ => n,
    }
}

fn stage_reader<'a>(stage: Stage, inner: Box<dyn Read + 'a>) -> Box<dyn Read + 'a> {
    match stage {
        Stage::Flate => Box::new(flate2::read::ZlibDecoder::new(inner)),
        Stage::AsciiHex => Box::new(AsciiHex::new(inner)),
        Stage::Ascii85 => Box::new(Ascii85::new(inner)),
        Stage::RunLength => Box::new(RunLength::new(inner)),
        Stage::Lzw { early_change } => Box::new(Lzw::new(inner, early_change)),
    }
}

/// Passes at most `left` bytes, and records that it did when `left` reaches zero: a stage that has
/// produced one byte more than its bound is over, whatever the next stage makes of the bytes.
struct Bounded<'a, R> {
    inner: R,
    left: u64,
    tripped: &'a Cell<bool>,
}

impl<R: Read> Read for Bounded<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.left == 0 {
            return Ok(0);
        }
        let max = (buf.len() as u64).min(self.left) as usize;
        let n = self.inner.read(&mut buf[..max])?;
        self.left -= n as u64;
        if self.left == 0 {
            self.tripped.set(true);
        }
        Ok(n)
    }
}

/// A small input buffer shared by the byte-at-a-time decoders.
struct Src<R> {
    inner: R,
    buf: [u8; 4096],
    pos: usize,
    len: usize,
}

impl<R: Read> Src<R> {
    fn new(inner: R) -> Self {
        Src {
            inner,
            buf: [0; 4096],
            pos: 0,
            len: 0,
        }
    }

    fn byte(&mut self) -> io::Result<Option<u8>> {
        if self.pos == self.len {
            self.len = self.inner.read(&mut self.buf)?;
            self.pos = 0;
            if self.len == 0 {
                return Ok(None);
            }
        }
        let b = self.buf[self.pos];
        self.pos += 1;
        Ok(Some(b))
    }
}

fn hex_value(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// ASCIIHexDecode: pairs of hex digits, white space and other bytes ignored, `>` ends the data, an
/// odd last digit is padded with zero.
struct AsciiHex<R> {
    src: Src<R>,
    high: Option<u8>,
    done: bool,
}

impl<R: Read> AsciiHex<R> {
    fn new(inner: R) -> Self {
        AsciiHex {
            src: Src::new(inner),
            high: None,
            done: false,
        }
    }
}

impl<R: Read> Read for AsciiHex<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let mut w = 0;
        while w < out.len() && !self.done {
            match self.src.byte()? {
                None | Some(b'>') => {
                    self.done = true;
                    if let Some(h) = self.high.take() {
                        out[w] = h << 4;
                        w += 1;
                    }
                }
                Some(c) => {
                    if let Some(v) = hex_value(c) {
                        match self.high.take() {
                            None => self.high = Some(v),
                            Some(h) => {
                                out[w] = (h << 4) | v;
                                w += 1;
                            }
                        }
                    }
                }
            }
        }
        Ok(w)
    }
}

/// ASCII85Decode: groups of five characters `!` to `u` make four bytes, `z` is four zero bytes, `~`
/// ends the data, a short last group of n characters makes n - 1 bytes.
struct Ascii85<R> {
    src: Src<R>,
    acc: u32,
    n: usize,
    pend: [u8; 4],
    pend_pos: usize,
    pend_len: usize,
    done: bool,
}

impl<R: Read> Ascii85<R> {
    fn new(inner: R) -> Self {
        Ascii85 {
            src: Src::new(inner),
            acc: 0,
            n: 0,
            pend: [0; 4],
            pend_pos: 0,
            pend_len: 0,
            done: false,
        }
    }

    fn set_pending(&mut self, bytes: [u8; 4], len: usize) {
        self.pend = bytes;
        self.pend_pos = 0;
        self.pend_len = len;
    }

    fn finish(&mut self) {
        self.done = true;
        if self.n >= 2 {
            let mut acc = self.acc;
            for _ in self.n..5 {
                acc = acc.wrapping_mul(85).wrapping_add(84);
            }
            let len = self.n - 1;
            self.set_pending(acc.to_be_bytes(), len);
        }
        self.n = 0;
        self.acc = 0;
    }
}

impl<R: Read> Read for Ascii85<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let mut w = 0;
        while w < out.len() {
            if self.pend_pos < self.pend_len {
                out[w] = self.pend[self.pend_pos];
                self.pend_pos += 1;
                w += 1;
                continue;
            }
            if self.done {
                break;
            }
            match self.src.byte()? {
                None | Some(b'~') => self.finish(),
                Some(b'z') if self.n == 0 => self.set_pending([0; 4], 4),
                Some(c @ b'!'..=b'u') => {
                    self.acc = self.acc.wrapping_mul(85).wrapping_add(u32::from(c - b'!'));
                    self.n += 1;
                    if self.n == 5 {
                        let bytes = self.acc.to_be_bytes();
                        self.set_pending(bytes, 4);
                        self.n = 0;
                        self.acc = 0;
                    }
                }
                Some(_) => {}
            }
        }
        Ok(w)
    }
}

/// RunLengthDecode: a length byte of 0 to 127 copies that many plus one bytes, 129 to 255 repeats
/// the next byte 257 minus that many times, 128 ends the data.
struct RunLength<R> {
    src: Src<R>,
    literal: u32,
    repeat: u32,
    repeat_byte: u8,
    done: bool,
}

impl<R: Read> RunLength<R> {
    fn new(inner: R) -> Self {
        RunLength {
            src: Src::new(inner),
            literal: 0,
            repeat: 0,
            repeat_byte: 0,
            done: false,
        }
    }
}

impl<R: Read> Read for RunLength<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        let mut w = 0;
        while w < out.len() {
            if self.repeat > 0 {
                let n = (self.repeat as usize).min(out.len() - w);
                out[w..w + n].fill(self.repeat_byte);
                w += n;
                self.repeat -= n as u32;
                continue;
            }
            if self.done {
                break;
            }
            if self.literal > 0 {
                match self.src.byte()? {
                    Some(b) => {
                        out[w] = b;
                        w += 1;
                        self.literal -= 1;
                    }
                    None => self.done = true,
                }
                continue;
            }
            match self.src.byte()? {
                None | Some(128) => self.done = true,
                Some(l) if l < 128 => self.literal = u32::from(l) + 1,
                Some(l) => match self.src.byte()? {
                    Some(b) => {
                        self.repeat = 257 - u32::from(l);
                        self.repeat_byte = b;
                    }
                    None => self.done = true,
                },
            }
        }
        Ok(w)
    }
}

/// LZWDecode through `weezl`, MSB first. Early change 1 is the PDF default.
struct Lzw<R> {
    inner: R,
    decoder: weezl::decode::Decoder,
    buf: Box<[u8; 8192]>,
    pos: usize,
    len: usize,
    eof: bool,
}

impl<R: Read> Lzw<R> {
    fn new(inner: R, early_change: bool) -> Self {
        let decoder = if early_change {
            weezl::decode::Decoder::with_tiff_size_switch(weezl::BitOrder::Msb, 8)
        } else {
            weezl::decode::Decoder::new(weezl::BitOrder::Msb, 8)
        };
        Lzw {
            inner,
            decoder,
            buf: Box::new([0; 8192]),
            pos: 0,
            len: 0,
            eof: false,
        }
    }
}

impl<R: Read> Read for Lzw<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        loop {
            if self.pos == self.len && !self.eof {
                self.len = self.inner.read(&mut self.buf[..])?;
                self.pos = 0;
                if self.len == 0 {
                    self.eof = true;
                }
            }
            let result = self
                .decoder
                .decode_bytes(&self.buf[self.pos..self.len], out);
            self.pos += result.consumed_in;
            match result.status {
                Err(_) => return Err(io::Error::new(io::ErrorKind::InvalidData, "lzw")),
                Ok(weezl::LzwStatus::Done) => return Ok(result.consumed_out),
                Ok(_) => {
                    if result.consumed_out > 0 {
                        return Ok(result.consumed_out);
                    }
                    if result.consumed_in == 0 && self.eof {
                        return Ok(0);
                    }
                    if result.consumed_in == 0 && self.pos < self.len {
                        // no progress with input on hand: stop rather than spin
                        return Ok(0);
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Image headers
// ---------------------------------------------------------------------------------------------

/// Width and height a JPEG states in its first start-of-frame marker (SOF0 to SOF15 except DHT, JPG
/// and DAC), found by stepping over marker segments; `None` when the header cannot be walked.
pub fn jpeg_dimensions(data: &[u8], max_segments: usize) -> Option<(u32, u32)> {
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return None;
    }
    let mut i = 2usize;
    let mut segments = 0usize;
    loop {
        if i >= data.len() || data[i] != 0xFF {
            return None;
        }
        while i < data.len() && data[i] == 0xFF {
            i += 1;
        }
        let marker = *data.get(i)?;
        i += 1;
        match marker {
            0x00 | 0x01 | 0xD0..=0xD8 => continue,
            0xD9 | 0xDA => return None,
            _ => {}
        }
        let seg = data.get(i..i + 2)?;
        let seg_len = usize::from(u16::from_be_bytes([seg[0], seg[1]]));
        if seg_len < 2 {
            return None;
        }
        if is_sof(marker) {
            let f = data.get(i + 2..i + 7)?;
            let h = u32::from(u16::from_be_bytes([f[1], f[2]]));
            let w = u32::from(u16::from_be_bytes([f[3], f[4]]));
            return Some((w, h));
        }
        i = i.checked_add(seg_len)?;
        segments += 1;
        if segments > max_segments {
            return None;
        }
    }
}

fn is_sof(marker: u8) -> bool {
    matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC)
}

/// The largest raster a JPEG header states anywhere in its first `window` bytes, for a file whose
/// markers cannot be walked (a reader that is lenient about junk may still decode it).
pub fn jpeg_dimensions_lenient(data: &[u8], window: usize) -> Option<(u32, u32)> {
    let win = &data[..data.len().min(window)];
    let mut best: Option<(u32, u32)> = None;
    let mut i = 0usize;
    while i + 9 <= win.len() {
        if win[i] == 0xFF && is_sof(win[i + 1]) {
            let seg_len = usize::from(u16::from_be_bytes([win[i + 2], win[i + 3]]));
            if seg_len >= 8 {
                let h = u32::from(u16::from_be_bytes([win[i + 5], win[i + 6]]));
                let w = u32::from(u16::from_be_bytes([win[i + 7], win[i + 8]]));
                if best.is_none_or(|(bw, bh)| {
                    u64::from(w) * u64::from(h) > u64::from(bw) * u64::from(bh)
                }) {
                    best = Some((w, h));
                }
            }
        }
        i += 1;
    }
    best
}

const JP2_SIGNATURE: [u8; 12] = [
    0, 0, 0, 0x0C, b'j', b'P', b' ', b' ', 0x0D, 0x0A, 0x87, 0x0A,
];
const J2K_SOC_SIZ: [u8; 4] = [0xFF, 0x4F, 0xFF, 0x51];

fn be32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}

/// Width and height of a JPEG 2000 image: the larger raster of the SIZ marker of its codestream
/// (the whole file for a bare codestream, the `jp2c` box of a JP2 file) and the `ihdr` box of a JP2
/// file. Boxes are walked, not searched for, so compressed data cannot pose as a header.
pub fn jpx_dimensions(data: &[u8], max_boxes: usize) -> Option<(u32, u32)> {
    let mut best: Option<(u32, u32)> = None;
    let mut consider = |w: u32, h: u32| {
        if best.is_none_or(|(bw, bh)| u64::from(w) * u64::from(h) > u64::from(bw) * u64::from(bh)) {
            best = Some((w, h));
        }
    };
    if data.starts_with(&J2K_SOC_SIZ) {
        return siz(data);
    }
    if !data.starts_with(&JP2_SIGNATURE) {
        return None;
    }
    let mut pos = 0usize;
    for _ in 0..max_boxes {
        let header = data.get(pos..pos + 8)?;
        let l_box = u64::from(be32(&header[..4]));
        let kind = [header[4], header[5], header[6], header[7]];
        let (body, end) = match l_box {
            0 => (pos + 8, data.len()),
            1 => {
                let x = data.get(pos + 8..pos + 16)?;
                let len = u64::from_be_bytes([x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7]]);
                (
                    pos + 16,
                    usize::try_from(len).ok().and_then(|l| pos.checked_add(l))?,
                )
            }
            n if n < 8 => return best,
            n => (pos + 8, pos.checked_add(usize::try_from(n).ok()?)?),
        };
        let end = end.min(data.len());
        match &kind {
            b"jp2h" => {
                let mut inner = body;
                for _ in 0..max_boxes {
                    let Some(h) = data.get(inner..inner + 8) else {
                        break;
                    };
                    let l = usize::try_from(be32(&h[..4])).ok()?;
                    if l < 8 {
                        break;
                    }
                    if &h[4..8] == b"ihdr" {
                        if let Some(f) = data.get(inner + 8..inner + 16) {
                            consider(be32(&f[4..8]), be32(&f[..4]));
                        }
                        break;
                    }
                    inner = inner.checked_add(l)?;
                    if inner >= end {
                        break;
                    }
                }
            }
            b"jp2c" => {
                if let Some((w, h)) = data.get(body..).and_then(siz) {
                    consider(w, h);
                }
                return best;
            }
            _ => {}
        }
        if end <= pos {
            return best;
        }
        pos = end;
    }
    best
}

/// The raster of the SIZ marker that must open a codestream: Xsiz - XOsiz by Ysiz - YOsiz.
fn siz(cs: &[u8]) -> Option<(u32, u32)> {
    if !cs.starts_with(&J2K_SOC_SIZ) {
        return None;
    }
    let f = cs.get(4..28)?;
    let (xsiz, ysiz, xo, yo) = (
        be32(&f[4..8]),
        be32(&f[8..12]),
        be32(&f[12..16]),
        be32(&f[16..20]),
    );
    Some((xsiz.saturating_sub(xo), ysiz.saturating_sub(yo)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(stage: Stage, data: &[u8]) -> Vec<u8> {
        let mut r = stage_reader(stage, Box::new(data));
        let mut out = Vec::new();
        let _ = r.read_to_end(&mut out);
        out
    }

    #[test]
    fn ascii_hex_matches_the_spec() {
        assert_eq!(run(Stage::AsciiHex, b"48 65 6C 6c6F>ignored"), b"Hello");
        assert_eq!(run(Stage::AsciiHex, b"414>"), b"A@");
        assert_eq!(run(Stage::AsciiHex, b""), b"");
    }

    #[test]
    fn ascii85_matches_the_adobe_example() {
        assert_eq!(run(Stage::Ascii85, b"87cURD]i,\"Ebo7~>"), b"Hello World");
        assert_eq!(run(Stage::Ascii85, b"z~>"), [0, 0, 0, 0]);
    }

    #[test]
    fn run_length_matches_the_spec() {
        assert_eq!(run(Stage::RunLength, b"\x03abcd\xFCa\x80"), b"abcdaaaaa");
        assert_eq!(run(Stage::RunLength, b"\x00x"), b"x");
        assert_eq!(
            run(Stage::RunLength, b"\x05ab"),
            b"ab",
            "short literal run ends at the data"
        );
    }

    #[test]
    fn lzw_matches_the_pdf_reference_example() {
        let got = run(
            Stage::Lzw { early_change: true },
            &[0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01],
        );
        assert_eq!(got, [45, 45, 45, 45, 45, 65, 45, 45, 45, 66]);
    }

    #[test]
    fn a_bomb_stops_one_byte_past_the_bound_with_a_fixed_scratch() {
        // 4 MiB of zeros through ASCIIHex-free Flate, bound 1 MiB
        use std::io::Write;
        let mut enc = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
        enc.write_all(&vec![0u8; 4 << 20]).unwrap();
        let z = enc.finish().unwrap();
        let chain = Chain {
            stages: vec![Stage::Flate],
            terminal: Terminal::None,
            predictor: Predictor::None,
        };
        let mut scratch = vec![0u8; 4096];
        let c = count(&z, &chain, 1 << 20, &mut scratch, 0);
        assert!(c.exceeded);
        assert_eq!(c.decoded, (1 << 20) + 1);
        let c = count(&z, &chain, 8 << 20, &mut scratch, 0);
        assert!(!c.exceeded);
        assert_eq!(c.decoded, 4 << 20);
    }

    #[test]
    fn png_predictor_arithmetic() {
        let p = Predictor::Png { row_bytes: 99 };
        assert_eq!(after_predictor(100_000, p), 99_000);
        assert_eq!(after_predictor(100_050, p), 99_000 + 49);
        assert_eq!(after_predictor(1, p), 0);
        assert_eq!(after_predictor(7, Predictor::Tiff), 7);
    }

    #[test]
    fn jpeg_and_jpx_headers() {
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 1, 2];
        jpeg.extend_from_slice(&[
            0xFF, 0xC2, 0x00, 0x0B, 8, 0x01, 0x00, 0x02, 0x00, 1, 1, 0x11, 0,
        ]);
        assert_eq!(jpeg_dimensions(&jpeg, 100), Some((512, 256)));
        assert_eq!(jpeg_dimensions(b"not a jpeg", 100), None);
        // junk before the markers: the strict walk gives up, the lenient scan still finds the frame
        let mut junk = vec![0xFF, 0xD8, 0x12, 0x34];
        junk.extend_from_slice(&jpeg[2..]);
        assert_eq!(jpeg_dimensions(&junk, 100), None);
        assert_eq!(jpeg_dimensions_lenient(&junk, 4096), Some((512, 256)));
        // DHT (C4) is not a frame header
        assert_eq!(
            jpeg_dimensions(&[0xFF, 0xD8, 0xFF, 0xC4, 0x00, 0x04, 0, 0, 0xFF, 0xDA], 100),
            None
        );

        let mut cs = vec![0xFF, 0x4F, 0xFF, 0x51, 0, 41, 0, 0];
        cs.extend_from_slice(&1000u32.to_be_bytes());
        cs.extend_from_slice(&2000u32.to_be_bytes());
        cs.extend_from_slice(&10u32.to_be_bytes());
        cs.extend_from_slice(&20u32.to_be_bytes());
        cs.extend_from_slice(&[0; 16]);
        assert_eq!(jpx_dimensions(&cs, 100), Some((990, 1980)));
        // a JP2 file: signature, ftyp, jp2h(ihdr), jp2c
        let mut jp2 = JP2_SIGNATURE.to_vec();
        jp2.extend_from_slice(&[
            0, 0, 0, 20, b'f', b't', b'y', b'p', b'j', b'p', b'2', b' ', 0, 0, 0, 0, b'j', b'p',
            b'2', b' ',
        ]);
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(&300u32.to_be_bytes()); // height
        ihdr.extend_from_slice(&400u32.to_be_bytes()); // width
        ihdr.extend_from_slice(&[0, 3, 7, 7, 0, 0]);
        let ihdr_box_len = 8 + ihdr.len();
        jp2.extend_from_slice(&((8 + ihdr_box_len) as u32).to_be_bytes());
        jp2.extend_from_slice(b"jp2h");
        jp2.extend_from_slice(&(ihdr_box_len as u32).to_be_bytes());
        jp2.extend_from_slice(b"ihdr");
        jp2.extend_from_slice(&ihdr);
        jp2.extend_from_slice(&((8 + cs.len()) as u32).to_be_bytes());
        jp2.extend_from_slice(b"jp2c");
        jp2.extend_from_slice(&cs);
        assert_eq!(jpx_dimensions(&jp2, 100), Some((990, 1980)));
        assert_eq!(jpx_dimensions(b"random bytes ihdr", 100), None);
    }
}
