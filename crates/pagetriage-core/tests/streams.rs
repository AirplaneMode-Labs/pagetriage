//! Stream accounting (S1-107, TD-70): `account_pdf_streams` bounds the fonts, images and content
//! streams of a PDF before a renderer opens it. Every bomb here is generated at run time
//! (`tests/support/bombs.rs`); none is a committed file.
//!
//! The rules under test are in `docs/detectors/streams.md`; the output shape is
//! `pagetriage.streams/0.1`.
#![cfg(feature = "pdf")]

mod support;

use std::time::Instant;

use pagetriage_core::structural::{StreamsReport, account_pdf_streams};
use serde_json::Value;
use support::bombs::{self, MIB, Spec};
use support::{Builder, Page};

const FONT_MAX: u64 = 32 * MIB as u64;
const IMAGE_MAX: u64 = 256 * MIB as u64;
const CONTENT_MAX: u64 = 64 * MIB as u64;
const TOTAL_MAX: u64 = 512 * MIB as u64;

fn run(bytes: &[u8]) -> Value {
    run_with(bytes, None)
}

fn run_with(bytes: &[u8], opts: Option<&str>) -> Value {
    let json = account_pdf_streams(bytes, opts).expect("accounting returns a report");
    serde_json::from_str(&json).unwrap()
}

fn timed(name: &str, bytes: &[u8]) -> Value {
    let t = Instant::now();
    let v = run(bytes);
    eprintln!(
        "STREAMS-TIME {name}: {} ms (input {} bytes, verdict {}, reason {:?})",
        t.elapsed().as_millis(),
        bytes.len(),
        v["verdict"],
        v["reason"]
    );
    v
}

fn refused(v: &Value, reason: &str) {
    assert_eq!(v["verdict"], "refuse", "{v}");
    assert_eq!(v["reason"], reason, "{v}");
}

fn kind<'a>(v: &'a Value, k: &str) -> &'a Value {
    &v["streams"]["by_kind"][k]
}

/// A one-page document with the given content stream (dictionary text, data) and font file.
fn doc(s: &Spec) -> Vec<u8> {
    bombs::document(s, 8, |_| {})
}

// ---------------------------------------------------------------------------------------------
// The generator itself
// ---------------------------------------------------------------------------------------------

#[test]
fn the_bomb_generator_makes_exactly_the_stated_size() {
    use std::io::Read;
    let z = bombs::zlib_zeros(3);
    let mut out = Vec::new();
    let mut dec = flate2::read::ZlibDecoder::new(&z[..]);
    let _ = dec.read_to_end(&mut out); // the zero checksum fails at the very end
    assert_eq!(out.len(), 3 * MIB);
    assert!(out.iter().all(|b| *b == 0));
    assert!(z.len() < 8 * 1024, "3 MiB of zeros is {} bytes", z.len());
}

// ---------------------------------------------------------------------------------------------
// Clean documents
// ---------------------------------------------------------------------------------------------

#[test]
fn a_clean_document_is_ok_with_per_kind_counts() {
    let pdf = doc(&Spec::default());
    let v = run(&pdf);
    assert_eq!(v["schema"], "pagetriage.streams/0.1", "{v}");
    assert_eq!(v["verdict"], "ok", "{v}");
    assert_eq!(v["reason"], "", "{v}");
    assert_eq!(v["streams"]["count"], 2, "{v}");
    assert_eq!(kind(&v, "content")["count"], 1, "{v}");
    assert_eq!(kind(&v, "font")["count"], 1, "{v}");
    assert_eq!(kind(&v, "image")["count"], 0, "{v}");
    assert_eq!(kind(&v, "content")["decoded_bytes"], 36, "{v}");
    assert_eq!(kind(&v, "font")["decoded_bytes"], 4, "{v}");
    assert_eq!(v["streams"]["early_stop"], false);
    assert_eq!(v["streams"]["decoded_capped"], false);
    assert_eq!(v["streams"]["total_decoded_bytes"], 40);
    assert_eq!(v["limits"]["font_decoded_max"], FONT_MAX);
    assert_eq!(v["limits"]["image_decoded_max"], IMAGE_MAX);
    assert_eq!(v["limits"]["image_raster_max"], IMAGE_MAX);
    assert_eq!(v["limits"]["content_decoded_max"], CONTENT_MAX);
    assert_eq!(v["limits"]["other_decoded_max"], CONTENT_MAX);
    assert_eq!(v["limits"]["total_decoded_max"], TOTAL_MAX);
    assert_eq!(v["limits"]["streams_max"], 3_000_000);
}

#[test]
fn the_support_page_builder_documents_are_ok_and_the_output_is_canonical() {
    let pdf =
        Page::new("BT /F1 12 Tf 72 700 Td (Some visible text on the page) Tj ET").build(Some("T"));
    let a = account_pdf_streams(&pdf, None).unwrap();
    let b = account_pdf_streams(&pdf, None).unwrap();
    assert_eq!(a, b, "same input, same bytes");
    let v: Value = serde_json::from_str(&a).unwrap();
    assert_eq!(v["verdict"], "ok");
    // canonical: compact, keys sorted (the typed report round-trips)
    assert!(!a.contains(": ") && !a.contains('\n'));
    let typed: StreamsReport = serde_json::from_str(&a).unwrap();
    assert_eq!(typed.schema, "pagetriage.streams/0.1");
    let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    let mut sorted = keys.clone();
    sorted.sort();
    assert_eq!(keys, sorted);
}

#[test]
fn a_big_but_legal_font_is_counted_not_refused() {
    let s = Spec {
        font_dict: "/Filter /FlateDecode /Length1 100",
        font_file: bombs::zlib_zeros(20),
        ..Spec::default()
    };
    let v = run(&doc(&s));
    assert_eq!(v["verdict"], "ok", "{v}");
    assert_eq!(kind(&v, "font")["decoded_bytes"], 20 * MIB as u64);
    assert_eq!(kind(&v, "font")["max_decoded_bytes"], 20 * MIB as u64);
    assert_eq!(kind(&v, "font")["over_limit"], false);
}

// ---------------------------------------------------------------------------------------------
// Bombs, one per kind
// ---------------------------------------------------------------------------------------------

#[test]
fn font_flate_bomb_of_1_gib_is_refused_before_it_is_decoded_in_full() {
    let s = Spec {
        font_dict: "/Filter /FlateDecode /Length1 100",
        font_file: bombs::zlib_zeros(1024),
        ..Spec::default()
    };
    let pdf = doc(&s);
    assert!(pdf.len() < 4 * MIB, "the 1 GiB bomb is {} bytes", pdf.len());
    let v = timed("font-1gib", &pdf);
    refused(&v, "font_over_limit");
    assert_eq!(kind(&v, "font")["over_limit"], true);
    assert_eq!(kind(&v, "font")["decoded_bytes"], FONT_MAX + 1);
    assert_eq!(v["streams"]["decoded_capped"], true);
    assert_eq!(v["streams"]["early_stop"], true);
}

#[test]
fn image_flate_bomb_of_1_gib_is_refused() {
    let s = Spec::default();
    let pdf = bombs::document(&s, 9, |b| {
        b.stream(
            8,
            "/Type /XObject /Subtype /Image /Width 1024 /Height 1024 /ColorSpace /DeviceGray \
             /BitsPerComponent 8 /Filter /FlateDecode",
            &bombs::zlib_zeros(1024),
        );
    });
    let v = timed("image-1gib", &pdf);
    refused(&v, "image_over_limit");
    assert_eq!(kind(&v, "image")["decoded_bytes"], IMAGE_MAX + 1);
}

#[test]
fn content_stream_over_the_cap_is_refused() {
    let s = Spec {
        content_dict: "/Filter /FlateDecode",
        content: bombs::zlib_zeros(65),
        ..Spec::default()
    };
    let v = timed("content-65mib", &doc(&s));
    refused(&v, "content_over_limit");
    assert_eq!(kind(&v, "content")["decoded_bytes"], CONTENT_MAX + 1);
}

#[test]
fn a_stream_nothing_refers_to_is_counted_as_other_and_bounded() {
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(8, "/Filter /FlateDecode", &bombs::zlib_zeros(100));
    });
    let v = timed("unreferenced-100mib", &pdf);
    refused(&v, "other_over_limit");
    assert_eq!(kind(&v, "other")["count"], 1);
}

#[test]
fn an_unreferenced_image_object_is_still_an_image() {
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray \
             /BitsPerComponent 8 /Filter /FlateDecode",
            &bombs::zlib_zeros(300),
        );
    });
    refused(&run(&pdf), "image_over_limit");
}

#[test]
fn a_font_file_that_nothing_refers_to_is_a_font_by_its_own_dictionary() {
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Filter /FlateDecode /Length1 10",
            &bombs::zlib_zeros(40),
        );
    });
    refused(&run(&pdf), "font_over_limit");
}

// ---------------------------------------------------------------------------------------------
// Declared sizes against what the data says
// ---------------------------------------------------------------------------------------------

#[test]
fn a_huge_declared_raster_with_tiny_data_is_refused_without_decoding() {
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Type /XObject /Subtype /Image /Width 100000 /Height 100000 /ColorSpace /DeviceGray \
             /BitsPerComponent 8 /Filter /FlateDecode",
            &bombs::zlib_small(&[0u8; 16]),
        );
    });
    let v = run(&pdf);
    refused(&v, "image_over_limit");
    assert_eq!(kind(&v, "image")["over_limit"], true);
}

#[test]
fn a_declared_raster_whose_product_overflows_is_refused() {
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Type /XObject /Subtype /Image /Width 4000000000 /Height 4000000000 /ColorSpace /DeviceGray \
             /BitsPerComponent 8 /Filter /FlateDecode",
            &bombs::zlib_small(&[0u8; 16]),
        );
    });
    refused(&run(&pdf), "image_over_limit");
}

#[test]
fn a_jpeg_whose_sof_is_larger_than_its_declared_size_is_refused() {
    let jpeg = bombs::jpeg_header(65000, 65000);
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Type /XObject /Subtype /Image /Width 10 /Height 10 /ColorSpace /DeviceRGB \
             /BitsPerComponent 8 /Filter /DCTDecode",
            &jpeg,
        );
    });
    let v = run(&pdf);
    refused(&v, "image_over_limit");
    // the raw JPEG bytes are tiny: only the codestream header gives it away
    assert!(kind(&v, "image")["raw_bytes"].as_u64().unwrap() < 200);
}

#[test]
fn a_jpeg_that_matches_its_declared_size_is_counted_raw() {
    let jpeg = bombs::jpeg_header(100, 100);
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceRGB \
             /BitsPerComponent 8 /Filter /DCTDecode",
            &jpeg,
        );
    });
    let v = run(&pdf);
    assert_eq!(v["verdict"], "ok", "{v}");
    assert_eq!(kind(&v, "image")["decoded_bytes"], jpeg.len() as u64);
}

#[test]
fn a_jpeg_2000_codestream_larger_than_declared_is_refused() {
    let jpx = bombs::jpx_codestream_header(70000, 70000);
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Type /XObject /Subtype /Image /Width 10 /Height 10 /ColorSpace /DeviceRGB \
             /BitsPerComponent 8 /Filter /JPXDecode",
            &jpx,
        );
    });
    refused(&run(&pdf), "image_over_limit");
}

#[test]
fn a_lying_length_that_is_too_small_does_not_hide_the_data() {
    let bomb = bombs::zlib_zeros(100);
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        bombs::stream_with_length(b, 8, "/Filter /FlateDecode", "5", &bomb);
    });
    let v = run(&pdf);
    refused(&v, "other_over_limit");
    // raw size is the larger of the declared length (5) and the endstream scan (the data, without
    // the end-of-line marker that precedes the keyword)
    assert_eq!(kind(&v, "other")["raw_bytes"], bomb.len() as u64);
}

#[test]
fn a_lying_length_that_is_far_too_large_is_bounded_by_the_file() {
    let bomb = bombs::zlib_zeros(100);
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        bombs::stream_with_length(b, 8, "/Filter /FlateDecode", "99999999999", &bomb);
    });
    let v = run(&pdf);
    refused(&v, "other_over_limit");
}

#[test]
fn a_length_that_agrees_with_endstream_is_used_as_is() {
    let pdf = doc(&Spec::default());
    let v = run(&pdf);
    // content 36 bytes, font file 4 bytes, no EOL is counted into either
    assert_eq!(kind(&v, "content")["raw_bytes"], 36);
    assert_eq!(kind(&v, "font")["raw_bytes"], 4);
}

#[test]
fn an_indirect_length_is_resolved() {
    let pdf = bombs::document(&Spec::default(), 10, |b| {
        let data = bombs::zlib_zeros(100);
        let mut body = b"<< /Filter /FlateDecode /Length 9 0 R >>\nstream\n".to_vec();
        body.extend_from_slice(&data);
        body.extend_from_slice(b"\nendstream");
        b.obj_bytes(8, &body);
        b.obj(9, &data.len().to_string());
    });
    refused(&run(&pdf), "other_over_limit");
}

// ---------------------------------------------------------------------------------------------
// Filter chains
// ---------------------------------------------------------------------------------------------

#[test]
fn ascii_hex_wrapping_a_flate_bomb_is_bounded() {
    let s = Spec {
        content_dict: "/Filter [/ASCIIHexDecode /FlateDecode]",
        content: bombs::hex_encode(&bombs::zlib_zeros(100)),
        ..Spec::default()
    };
    refused(&timed("asciihex-flate", &doc(&s)), "content_over_limit");
}

#[test]
fn flate_inside_flate_is_bounded_at_every_stage() {
    // the inner stream is the bomb; the outer one is a perfectly ordinary Flate of it
    let inner = bombs::zlib_zeros(1024);
    let outer = bombs::zlib_small(&inner);
    let s = Spec {
        content_dict: "/Filter [/FlateDecode /FlateDecode]",
        content: outer,
        ..Spec::default()
    };
    let v = timed("flate-in-flate", &doc(&s));
    refused(&v, "content_over_limit");
}

#[test]
fn an_intermediate_stage_over_the_cap_is_a_refusal_even_if_the_next_stage_shrinks_it() {
    // 70 MiB of zeros through Flate, then ASCIIHex (zeros are not hex digits, so it decodes to
    // nothing): the first stage alone is over the 64 MiB content cap.
    let s = Spec {
        content_dict: "/Filter [/FlateDecode /ASCIIHexDecode]",
        content: bombs::zlib_zeros(70),
        ..Spec::default()
    };
    refused(&run(&doc(&s)), "content_over_limit");
}

#[test]
fn flate_then_a_png_predictor_counts_the_unpredicted_size() {
    // 1000 rows of (1 tag byte + 99 data bytes): 100,000 bytes out of Flate, 99,000 after the predictor
    let rows = 1000usize;
    let raw: Vec<u8> = (0..rows)
        .flat_map(|_| std::iter::repeat_n(0u8, 100))
        .collect();
    let s = Spec {
        content_dict: "/Filter /FlateDecode /DecodeParms << /Predictor 15 /Columns 99 /Colors 1 /BitsPerComponent 8 >>",
        content: bombs::zlib_small(&raw),
        ..Spec::default()
    };
    let v = run(&doc(&s));
    assert_eq!(v["verdict"], "ok", "{v}");
    assert_eq!(kind(&v, "content")["decoded_bytes"], 99_000, "{v}");
}

#[test]
fn flate_with_a_predictor_is_still_bounded() {
    let s = Spec {
        content_dict: "/Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 1000 >>",
        content: bombs::zlib_zeros(100),
        ..Spec::default()
    };
    refused(&run(&doc(&s)), "content_over_limit");
}

#[test]
fn a_tiff_predictor_does_not_change_the_size() {
    let s = Spec {
        content_dict: "/Filter /FlateDecode /DecodeParms << /Predictor 2 /Columns 10 >>",
        content: bombs::zlib_small(&[1u8; 500]),
        ..Spec::default()
    };
    assert_eq!(kind(&run(&doc(&s)), "content")["decoded_bytes"], 500);
}

#[test]
fn a_predictor_that_is_not_the_last_stage_is_unaccounted() {
    let s = Spec {
        content_dict: "/Filter [/FlateDecode /ASCIIHexDecode] /DecodeParms [<< /Predictor 15 /Columns 4 >> null]",
        content: bombs::zlib_small(b"0000"),
        ..Spec::default()
    };
    refused(&run(&doc(&s)), "unaccounted");
}

#[test]
fn an_unknown_filter_is_unaccounted() {
    let s = Spec {
        content_dict: "/Filter /MadeUpDecode",
        content: b"abc".to_vec(),
        ..Spec::default()
    };
    let v = run(&doc(&s));
    refused(&v, "unaccounted");
}

#[test]
fn a_filter_chain_longer_than_the_limit_is_unaccounted() {
    let names = std::iter::repeat_n("/ASCIIHexDecode", 12)
        .collect::<Vec<_>>()
        .join(" ");
    let dict = format!("/Filter [{names}]");
    let s = Spec {
        content_dict: &dict,
        content: b"41>".to_vec(),
        ..Spec::default()
    };
    refused(&run(&doc(&s)), "unaccounted");
}

#[test]
fn a_filter_name_with_hex_escapes_is_the_same_filter() {
    // /Fl#61teDecode is /FlateDecode; a reader decodes the escape, so the accounting must too
    let s = Spec {
        content_dict: "/Filter /Fl#61teDecode",
        content: bombs::zlib_zeros(100),
        ..Spec::default()
    };
    refused(&run(&doc(&s)), "content_over_limit");
}

#[test]
fn filter_abbreviations_are_the_same_filters() {
    let s = Spec {
        content_dict: "/Filter [/AHx /Fl]",
        content: bombs::hex_encode(&bombs::zlib_zeros(100)),
        ..Spec::default()
    };
    refused(&run(&doc(&s)), "content_over_limit");
}

#[test]
fn ascii85_runlength_lzw_and_asciihex_decode_to_the_documented_sizes() {
    // ASCII85 of "Hello World" (the Adobe example), RunLength and LZW from the PDF reference
    let cases: [(&str, &[u8], u64); 4] = [
        ("/Filter /ASCII85Decode", b"87cURD]i,\"Ebo7~>", 11),
        ("/Filter /ASCIIHexDecode", b"48656C6C6F>", 5),
        // 4 literal bytes, then a run of 5 'a' (257 - 252), then EOD
        ("/Filter /RunLengthDecode", b"\x03abcd\xFCa\x80", 9),
        // the PDF reference's LZW example, early change 1
        (
            "/Filter /LZWDecode",
            b"\x80\x0B\x60\x50\x22\x0C\x0C\x85\x01",
            10,
        ),
    ];
    for (dict, data, want) in cases {
        let s = Spec {
            content_dict: dict,
            content: data.to_vec(),
            ..Spec::default()
        };
        let v = run(&doc(&s));
        assert_eq!(v["verdict"], "ok", "{dict}: {v}");
        assert_eq!(kind(&v, "content")["decoded_bytes"], want, "{dict}: {v}");
    }
}

#[test]
fn an_lzw_bomb_is_bounded() {
    // LZW cannot be repeated segment by segment; 70 MiB of zeros is encoded in one go
    let big = bombs::lzw_encode(&vec![0u8; 70 * MIB]);
    assert!(
        big.len() < 4 * MIB,
        "70 MiB of zeros is {} LZW bytes",
        big.len()
    );
    let s = Spec {
        content_dict: "/Filter /LZWDecode",
        content: big,
        ..Spec::default()
    };
    refused(&timed("lzw-70mib", &doc(&s)), "content_over_limit");
}

#[test]
fn a_decode_error_ends_the_count_it_is_not_a_refusal() {
    // zlib header, then garbage: pdf.js and lopdf both stop at the error
    let s = Spec {
        content_dict: "/Filter /FlateDecode",
        content: vec![0x78, 0x9C, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        ..Spec::default()
    };
    let v = run(&doc(&s));
    assert_eq!(v["verdict"], "ok", "{v}");
    assert_eq!(kind(&v, "content")["decoded_bytes"], 0);
}

// ---------------------------------------------------------------------------------------------
// Object streams, revisions, structure the parser cannot vouch for
// ---------------------------------------------------------------------------------------------

#[test]
fn an_object_stream_bomb_is_refused_as_other() {
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(
            8,
            "/Type /ObjStm /N 1 /First 4 /Filter /FlateDecode",
            &bombs::zlib_zeros(100),
        );
    });
    refused(&timed("objstm-100mib", &pdf), "other_over_limit");
}

#[test]
fn an_object_stream_full_of_stream_lookalikes_is_one_other_stream() {
    // an object stream whose text contains many 'obj << >> stream ... endstream' lookalikes; members of an
    // object stream are not stream objects, so the container is the only stream counted
    let mut inner = Vec::new();
    for i in 0..500 {
        inner.extend_from_slice(
            format!(
                "{} 0 obj << /Length 3 >> stream\nabc\nendstream endobj\n",
                100 + i
            )
            .as_bytes(),
        );
    }
    let pdf = bombs::document(&Spec::default(), 9, |b| {
        b.stream(8, "/Type /ObjStm /N 0 /First 0", &inner);
    });
    let v = run(&pdf);
    assert_eq!(v["verdict"], "ok", "{v}");
    assert_eq!(kind(&v, "other")["count"], 1, "{v}");
    assert_eq!(kind(&v, "other")["decoded_bytes"], inner.len() as u64);
}

#[test]
fn a_replaced_revision_of_a_stream_is_still_counted() {
    let mut b = Builder::new();
    bombs::base(&mut b, &Spec::default());
    b.stream(8, "/Filter /FlateDecode", &bombs::zlib_zeros(100));
    b.finish(1, None, 9);
    // the update replaces object 8 with a tiny stream: the old bytes are still in the file
    b.stream(8, "", b"tiny");
    b.finish(1, None, 9);
    let v = run(&b.out);
    refused(&v, "other_over_limit");
}

#[test]
fn a_document_that_needs_cross_reference_repair_is_unaccounted() {
    let mut pdf = doc(&Spec::default());
    let at = pdf.windows(9).rposition(|w| w == b"startxref").unwrap();
    // point startxref somewhere that is not a cross-reference table
    let mut broken = pdf[..at].to_vec();
    broken.extend_from_slice(b"startxref\n17\n%%EOF\n");
    pdf = broken;
    let v = run(&pdf);
    refused(&v, "unaccounted");
}

#[test]
fn unaccounted_outranks_every_limit_reason() {
    // a font bomb in a file that also needs repair: the structure cannot be trusted, so that wins
    let s = Spec {
        font_dict: "/Filter /FlateDecode /Length1 100",
        font_file: bombs::zlib_zeros(100),
        ..Spec::default()
    };
    let mut pdf = doc(&s);
    let at = pdf.windows(9).rposition(|w| w == b"startxref").unwrap();
    pdf.truncate(at);
    pdf.extend_from_slice(b"startxref\n17\n%%EOF\n");
    refused(&run(&pdf), "unaccounted");
}

#[test]
fn not_a_pdf_and_empty_input_are_unaccounted_not_an_error() {
    refused(&run(b"definitely not a pdf"), "unaccounted");
    refused(&run(b""), "unaccounted");
    refused(&run(&[0xFF; 4096]), "unaccounted");
}

#[test]
fn a_truncated_pdf_is_unaccounted() {
    let pdf = doc(&Spec::default());
    refused(&run(&pdf[..pdf.len() / 2]), "unaccounted");
}

#[test]
fn an_encrypted_document_is_unaccounted_because_its_streams_cannot_be_counted() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/golden/pdf/encrypted.pdf");
    let pdf = std::fs::read(path).unwrap();
    refused(&run(&pdf), "unaccounted");
}

#[test]
fn a_stream_the_scan_cannot_parse_is_unaccounted_never_skipped() {
    // an object whose dictionary the scan cannot close, followed by the stream keyword
    let mut b = Builder::new();
    bombs::base(&mut b, &Spec::default());
    b.obj_bytes(
        8,
        b"<< /Filter /FlateDecode /Broken [1 2 >>\nstream\nabc\nendstream",
    );
    b.finish(1, None, 9);
    let v = run(&b.out);
    // lopdf may or may not load it; either way a stream was seen that nobody could classify
    refused(&v, "unaccounted");
}

#[test]
fn an_object_hidden_inside_another_streams_data_is_unaccounted() {
    // object 8's data holds the text of an object 9 (a bomb); the cross-reference table points
    // object 9 at that text, so a reader opens it while a scan that skips stream data never sees it
    let bomb = bombs::zlib_zeros(100);
    let mut hidden = format!(
        "9 0 obj\n<< /Filter /FlateDecode /Length {} >>\nstream\n",
        bomb.len()
    )
    .into_bytes();
    hidden.extend_from_slice(&bomb);
    hidden.extend_from_slice(b"\nendstream\nendobj\n");
    let mut b = Builder::new();
    bombs::base(&mut b, &Spec::default());
    let host_start = b.out.len();
    let mut data = b"padding ".to_vec();
    let hidden_at = data.len();
    data.extend_from_slice(&hidden);
    b.stream(8, "", &data);
    let body_start = host_start + format!("8 0 obj\n<< /Length {} >>\nstream\n", data.len()).len();
    b.alias_offset(9, body_start + hidden_at);
    b.finish(1, None, 10);
    let v = run(&b.out);
    refused(&v, "unaccounted");
}

#[test]
fn a_stream_without_endstream_runs_to_the_end_of_the_file_and_is_counted() {
    let mut b = Builder::new();
    bombs::base(&mut b, &Spec::default());
    b.finish(1, None, 8);
    // an update with a stream that never ends (no endstream before EOF)
    let tail = bombs::zlib_zeros(100);
    let mut out = b.out.clone();
    out.extend_from_slice(b"8 0 obj\n<< /Filter /FlateDecode >>\nstream\n");
    out.extend_from_slice(&tail);
    let v = run(&out);
    // whatever the parser makes of the damaged tail, it must not come back "ok" with a 100 MiB stream unseen
    assert_eq!(v["verdict"], "refuse", "{v}");
}

// ---------------------------------------------------------------------------------------------
// Many streams, and the cumulative bound
// ---------------------------------------------------------------------------------------------

#[test]
fn a_hundred_thousand_streams_of_1_mib_stop_early_at_the_total_cap() {
    let one = bombs::zlib_zeros(1);
    let pdf = bombs::document(&Spec::default(), 100_200, |b| {
        for n in 0..100_000u32 {
            b.stream(100 + n, "/Filter /FlateDecode", &one);
        }
    });
    let v = timed("100k-streams-1mib-each", &pdf);
    refused(&v, "total_over_limit");
    assert_eq!(v["streams"]["early_stop"], true);
    assert_eq!(v["streams"]["count"], 100_002, "{v}");
    assert_eq!(v["streams"]["total_decoded_bytes"], TOTAL_MAX + 1);
}

#[test]
fn a_hundred_thousand_empty_streams_are_ok_and_too_many_under_a_lower_limit() {
    let pdf = bombs::document(&Spec::default(), 100_200, |b| {
        for n in 0..100_000u32 {
            b.stream(100 + n, "", b"");
        }
    });
    let v = timed("100k-empty-streams", &pdf);
    assert_eq!(v["verdict"], "ok", "{v}");
    assert_eq!(v["streams"]["count"], 100_002);
    let v = run_with(&pdf, Some(r#"{"params": "streams_max = 1000"}"#));
    refused(&v, "too_many_streams");
    assert_eq!(v["limits"]["streams_max"], 1000);
}

#[test]
fn the_per_stream_reason_is_the_first_in_object_id_order() {
    // object 4 (a content stream) is over its cap and so is object 7 (the font file); 4 comes first
    let s = Spec {
        content_dict: "/Filter /FlateDecode",
        content: bombs::zlib_zeros(65),
        font_dict: "/Filter /FlateDecode /Length1 100",
        font_file: bombs::zlib_zeros(40),
    };
    refused(&run(&doc(&s)), "content_over_limit");
}

#[test]
fn a_limit_reason_outranks_too_many_streams() {
    let s = Spec {
        font_dict: "/Filter /FlateDecode /Length1 100",
        font_file: bombs::zlib_zeros(40),
        ..Spec::default()
    };
    let v = run_with(&doc(&s), Some(r#"{"params": "streams_max = 1"}"#));
    refused(&v, "font_over_limit");
}

// ---------------------------------------------------------------------------------------------
// Options can only lower the limits
// ---------------------------------------------------------------------------------------------

#[test]
fn an_option_can_lower_a_limit() {
    let s = Spec {
        font_dict: "/Filter /FlateDecode /Length1 100",
        font_file: bombs::zlib_zeros(2),
        ..Spec::default()
    };
    let pdf = doc(&s);
    assert_eq!(run(&pdf)["verdict"], "ok");
    let v = run_with(&pdf, Some(r#"{"params": "font_decoded_max = 1048576"}"#));
    refused(&v, "font_over_limit");
    assert_eq!(v["limits"]["font_decoded_max"], 1_048_576);
}

#[test]
fn an_option_cannot_raise_a_limit() {
    let s = Spec {
        font_dict: "/Filter /FlateDecode /Length1 100",
        font_file: bombs::zlib_zeros(40),
        ..Spec::default()
    };
    let pdf = doc(&s);
    let raised = r#"{"params": "font_decoded_max = 9999999999999\nimage_decoded_max = 9999999999999\nimage_raster_max = 9999999999999\ncontent_decoded_max = 9999999999999\nother_decoded_max = 9999999999999\ntotal_decoded_max = 9999999999999\nstreams_max = 999999999999"}"#;
    let v = run_with(&pdf, Some(raised));
    refused(&v, "font_over_limit");
    let plain = run(&pdf);
    assert_eq!(v["limits"], plain["limits"], "a raise is ignored");
}

#[test]
fn unknown_option_keys_and_bad_values_are_errors() {
    let pdf = doc(&Spec::default());
    for opts in [
        r#"{"nope": 1}"#,
        r#"{"params": "font_decoded_max = \"big\""}"#,
        r#"{"params": "no_such_limit = 5"}"#,
        r#"{"params": "font_decoded_max = 0"}"#,
        r#"{"params": "font_decoded_max = -1"}"#,
        r#"{"params": "this is not toml"}"#,
        "not json",
    ] {
        assert!(
            account_pdf_streams(&pdf, Some(opts)).is_err(),
            "{opts} should be refused"
        );
    }
    // empty and `{}` mean defaults
    assert!(account_pdf_streams(&pdf, Some("")).is_ok());
    assert!(account_pdf_streams(&pdf, Some("{}")).is_ok());
}

// ---------------------------------------------------------------------------------------------
// The report carries no document bytes
// ---------------------------------------------------------------------------------------------

#[test]
fn notes_are_fixed_templates_and_no_document_text_reaches_the_report() {
    let sentinel = "ZZSENTINELZZ";
    let mut b = Builder::new();
    bombs::base(&mut b, &Spec::default());
    b.stream(
        8,
        &format!("/{sentinel} /{sentinel}2 (secret {sentinel}) /Filter /FlateDecode /Subtype /{sentinel}3"),
        &bombs::zlib_zeros(100),
    );
    b.finish(1, None, 9);
    let out = account_pdf_streams(&b.out, None).unwrap();
    assert!(
        !out.contains(sentinel),
        "document text leaked into the report: {out}"
    );
    // a non-PDF carrying the sentinel
    let out = account_pdf_streams(format!("not a pdf {sentinel}").as_bytes(), None).unwrap();
    assert!(!out.contains(sentinel), "{out}");
    let v: Value = serde_json::from_str(&out).unwrap();
    for n in v["notes"].as_array().unwrap() {
        let n = n.as_str().unwrap();
        assert!(n.is_ascii() && n.len() < 200, "{n}");
        assert!(
            n.chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || " ,.:;()-_'%".contains(c)),
            "note has an unexpected character: {n}"
        );
    }
}

// ---------------------------------------------------------------------------------------------
// The golden documents of the structural layer
// ---------------------------------------------------------------------------------------------

#[test]
fn every_golden_structure_pdf_is_ok_except_the_encrypted_one() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/golden/pdf");
    let mut seen = 0;
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "pdf") {
            continue;
        }
        let name = path.file_stem().unwrap().to_string_lossy().into_owned();
        let v = run(&std::fs::read(&path).unwrap());
        if name == "encrypted" {
            refused(&v, "unaccounted");
        } else {
            assert_eq!(v["verdict"], "ok", "{name}: {v}");
        }
        seen += 1;
    }
    assert!(seen >= 6, "found {seen} golden PDFs");
}
