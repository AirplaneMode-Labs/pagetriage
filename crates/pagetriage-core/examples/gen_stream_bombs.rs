//! Writes the synthetic stream bombs of `tests/streams.rs` into a folder, so that a shell script can
//! run the CLI on each under `/usr/bin/time` and log the peak memory (`scripts/stream-bombs.sh`).
//! Nothing it writes is ever committed: the folder is the caller's scratch space.
//!
//! `cargo run --release -p pagetriage-core --features pdf --example gen_stream_bombs -- <dir>`
#![cfg(feature = "pdf")]

#[path = "../tests/support/mod.rs"]
mod support;

use std::fs;
use std::path::PathBuf;

use support::bombs::{self, MIB, Spec};

fn main() {
    let dir = PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("usage: gen_stream_bombs <dir>"),
    );
    fs::create_dir_all(&dir).unwrap();
    let put = |name: &str, bytes: Vec<u8>| {
        println!("{name} {}", bytes.len());
        fs::write(dir.join(name), bytes).unwrap();
    };

    put("clean.pdf", bombs::document(&Spec::default(), 8, |_| {}));
    put(
        "font-1gib.pdf",
        bombs::document(
            &Spec {
                font_dict: "/Filter /FlateDecode /Length1 100",
                font_file: bombs::zlib_zeros(1024),
                ..Spec::default()
            },
            8,
            |_| {},
        ),
    );
    put(
        "image-1gib.pdf",
        bombs::document(&Spec::default(), 9, |b| {
            b.stream(
                8,
                "/Type /XObject /Subtype /Image /Width 1024 /Height 1024 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode",
                &bombs::zlib_zeros(1024),
            );
        }),
    );
    put(
        "content-65mib.pdf",
        bombs::document(
            &Spec {
                content_dict: "/Filter /FlateDecode",
                content: bombs::zlib_zeros(65),
                ..Spec::default()
            },
            8,
            |_| {},
        ),
    );
    put(
        "objstm-1gib.pdf",
        bombs::document(&Spec::default(), 9, |b| {
            b.stream(
                8,
                "/Type /ObjStm /N 1 /First 4 /Filter /FlateDecode",
                &bombs::zlib_zeros(1024),
            );
        }),
    );
    put(
        "unreferenced-1gib.pdf",
        bombs::document(&Spec::default(), 9, |b| {
            b.stream(8, "/Filter /FlateDecode", &bombs::zlib_zeros(1024));
        }),
    );
    put(
        "asciihex-flate-1gib.pdf",
        bombs::document(
            &Spec {
                content_dict: "/Filter [/ASCIIHexDecode /FlateDecode]",
                content: bombs::hex_encode(&bombs::zlib_zeros(1024)),
                ..Spec::default()
            },
            8,
            |_| {},
        ),
    );
    put(
        "flate-in-flate-1gib.pdf",
        bombs::document(
            &Spec {
                content_dict: "/Filter [/FlateDecode /FlateDecode]",
                content: bombs::zlib_small(&bombs::zlib_zeros(1024)),
                ..Spec::default()
            },
            8,
            |_| {},
        ),
    );
    put(
        "lzw-70mib.pdf",
        bombs::document(
            &Spec {
                content_dict: "/Filter /LZWDecode",
                content: bombs::lzw_encode(&vec![0u8; 70 * MIB]),
                ..Spec::default()
            },
            8,
            |_| {},
        ),
    );
    put(
        "jpeg-sof-65000.pdf",
        bombs::document(&Spec::default(), 9, |b| {
            b.stream(
                8,
                "/Type /XObject /Subtype /Image /Width 10 /Height 10 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode",
                &bombs::jpeg_header(65000, 65000),
            );
        }),
    );
    put(
        "raster-declared-100000.pdf",
        bombs::document(&Spec::default(), 9, |b| {
            b.stream(
                8,
                "/Type /XObject /Subtype /Image /Width 100000 /Height 100000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode",
                &bombs::zlib_small(&[0u8; 16]),
            );
        }),
    );
    put(
        "lying-length-1gib.pdf",
        bombs::document(&Spec::default(), 9, |b| {
            bombs::stream_with_length(b, 8, "/Filter /FlateDecode", "5", &bombs::zlib_zeros(1024));
        }),
    );
    put(
        "streams-100k-x-1mib.pdf",
        bombs::document(&Spec::default(), 100_200, |b| {
            let one = bombs::zlib_zeros(1);
            for n in 0..100_000u32 {
                b.stream(100 + n, "/Filter /FlateDecode", &one);
            }
        }),
    );
    put(
        "streams-100k-empty.pdf",
        bombs::document(&Spec::default(), 100_200, |b| {
            for n in 0..100_000u32 {
                b.stream(100 + n, "", b"");
            }
        }),
    );
    let mut broken = bombs::document(
        &Spec {
            font_dict: "/Filter /FlateDecode /Length1 100",
            font_file: bombs::zlib_zeros(100),
            ..Spec::default()
        },
        8,
        |_| {},
    );
    let at = broken.windows(9).rposition(|w| w == b"startxref").unwrap();
    broken.truncate(at);
    broken.extend_from_slice(b"startxref\n17\n%%EOF\n");
    put("xref-broken-with-bomb.pdf", broken);
}
