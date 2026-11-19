//! Synthetic stream bombs for the stream-accounting tests (S1-107). Everything is generated at run
//! time from a few lines of code and is never committed: a 1 GiB bomb is about 1 MB of deflate
//! data, and the 100,000-stream case is about 100 MB, which is why nothing here is a fixture file.
//!
//! The deflate bombs are made from one sync-flushed segment of zeros repeated many times, so the
//! generator is fast even in a debug build.
#![allow(dead_code)]

use std::io::Write;

use flate2::Compression;
use flate2::write::ZlibEncoder;

use super::Builder;

pub const MIB: usize = 1 << 20;

/// One byte-aligned deflate segment that inflates to 1 MiB of zeros (a sync flush ends it).
fn zero_segment() -> Vec<u8> {
    let zeros = vec![0u8; MIB];
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::best());
    enc.write_all(&zeros).unwrap();
    enc.flush().unwrap();
    let after_first = enc.get_ref().len();
    enc.write_all(&zeros).unwrap();
    enc.flush().unwrap();
    enc.get_ref()[after_first..].to_vec()
}

/// A zlib stream that inflates to exactly `mib` MiB of zeros, with its true Adler-32 (the sum of
/// zeros is 1 and the running sum is the byte count modulo 65521).
pub fn zlib_zeros(mib: usize) -> Vec<u8> {
    let seg = zero_segment();
    let mut out = Vec::with_capacity(2 + seg.len() * mib + 6);
    out.extend_from_slice(&[0x78, 0xDA]);
    for _ in 0..mib {
        out.extend_from_slice(&seg);
    }
    out.extend_from_slice(&[0x03, 0x00]);
    let b = ((mib as u64) << 20) % 65521;
    out.extend_from_slice(&(((b as u32) << 16) | 1).to_be_bytes());
    out
}

/// A zlib stream of `n` zero bytes for a small `n` (a real stream with a correct checksum).
pub fn zlib_small(data: &[u8]) -> Vec<u8> {
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::best());
    enc.write_all(data).unwrap();
    enc.finish().unwrap()
}

pub fn hex_encode(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() * 2 + 1);
    for b in data {
        out.extend_from_slice(format!("{b:02X}").as_bytes());
    }
    out.push(b'>');
    out
}

/// LZW (PDF, MSB first, early change 1) of `data`, made by the same crate the decoder uses.
pub fn lzw_encode(data: &[u8]) -> Vec<u8> {
    let mut enc = weezl::encode::Encoder::with_tiff_size_switch(weezl::BitOrder::Msb, 8);
    enc.encode(data).unwrap()
}

/// A baseline JPEG header (no scan data) whose SOF0 states `w` x `h`.
pub fn jpeg_header(w: u16, h: u16) -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8];
    // an APP0 segment first, so the scan has to step over a segment
    v.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x10]);
    v.extend_from_slice(b"JFIF\0\x01\x01\x00\x00\x01\x00\x01\x00\x00");
    // SOF0: length 17, precision 8, height, width, 3 components
    v.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]);
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&[0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
    // SOS and EOI (no real entropy-coded data)
    v.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]);
    v.extend_from_slice(&[0xFF, 0xD9]);
    v
}

/// A bare JPEG 2000 codestream header whose SIZ states `w` x `h`.
pub fn jpx_codestream_header(w: u32, h: u32) -> Vec<u8> {
    let mut v = vec![0xFF, 0x4F, 0xFF, 0x51];
    v.extend_from_slice(&41u16.to_be_bytes()); // Lsiz for one component
    v.extend_from_slice(&0u16.to_be_bytes()); // Rsiz
    v.extend_from_slice(&w.to_be_bytes()); // Xsiz
    v.extend_from_slice(&h.to_be_bytes()); // Ysiz
    v.extend_from_slice(&0u32.to_be_bytes()); // XOsiz
    v.extend_from_slice(&0u32.to_be_bytes()); // YOsiz
    v.extend_from_slice(&64u32.to_be_bytes()); // XTsiz
    v.extend_from_slice(&64u32.to_be_bytes()); // YTsiz
    v.extend_from_slice(&0u32.to_be_bytes()); // XTOsiz
    v.extend_from_slice(&0u32.to_be_bytes()); // YTOsiz
    v.extend_from_slice(&1u16.to_be_bytes()); // Csiz
    v.extend_from_slice(&[0x07, 0x01, 0x01]); // Ssiz, XRsiz, YRsiz
    v
}

/// The pieces of a one-page document whose interesting streams the caller chooses. Object
/// numbers: 1 catalog, 2 pages, 3 page, 4 content stream, 5 font, 6 font descriptor, 7 font file.
pub struct Spec<'a> {
    pub content_dict: &'a str,
    pub content: Vec<u8>,
    pub font_dict: &'a str,
    pub font_file: Vec<u8>,
}

impl Default for Spec<'_> {
    fn default() -> Self {
        Spec {
            content_dict: "",
            content: b"BT /F1 12 Tf 72 700 Td (Hello) Tj ET".to_vec(),
            font_dict: "/Length1 4",
            font_file: b"\0\x01\0\0".to_vec(),
        }
    }
}

/// Write objects 1 to 7 into `b`.
pub fn base(b: &mut Builder, s: &Spec) {
    b.obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
    b.obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
    b.obj(
        3,
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R \
         /Resources << /Font << /F1 5 0 R >> >> >>",
    );
    b.stream(4, s.content_dict, &s.content);
    b.obj(
        5,
        "<< /Type /Font /Subtype /TrueType /BaseFont /Test /FirstChar 32 /LastChar 32 \
         /Widths [500] /FontDescriptor 6 0 R >>",
    );
    b.obj(
        6,
        "<< /Type /FontDescriptor /FontName /Test /Flags 32 /FontBBox [0 0 1000 1000] \
         /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 700 /StemV 80 /FontFile2 7 0 R >>",
    );
    b.stream(7, s.font_dict, &s.font_file);
}

/// A complete document from a spec, with `more` adding further objects (numbers from 8) before
/// the cross-reference table is written. `size` is the /Size to state.
pub fn document(s: &Spec, size: u32, more: impl FnOnce(&mut Builder)) -> Vec<u8> {
    let mut b = Builder::new();
    base(&mut b, s);
    more(&mut b);
    b.finish(1, None, size);
    b.out
}

/// A stream object whose /Length text is chosen by the caller (a lying length).
pub fn stream_with_length(b: &mut Builder, num: u32, dict: &str, length_text: &str, data: &[u8]) {
    let mut body = format!("<< {dict} /Length {length_text} >>\nstream\n").into_bytes();
    body.extend_from_slice(data);
    body.extend_from_slice(b"\nendstream");
    b.obj_bytes(num, &body);
}
