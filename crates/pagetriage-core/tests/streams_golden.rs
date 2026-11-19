//! Golden snapshots of the stream accounting (S1-107): every PDF in `tests/golden/pdf/` (the
//! structural layer's synthetic documents) and every seed in `tests/golden/streams_inputs/` (tiny
//! synthetic bombs, each under 100 KB) must give exactly `tests/golden/streams/NAME.json`.
//! The Python and WASM runners in `tests/determinism/` check the same files, which is what shows
//! the three builds agree.
//!
//! The existing structure reports are not touched by this call: `tests/golden/pdf_expected/` stays
//! byte for byte as it was (the golden diff for old inputs is empty).
//!
//! Regenerate after an intentional change, then review the diff:
//! `UPDATE_GOLDEN=1 cargo test -p pagetriage-core --features pdf --test streams_golden`
#![cfg(feature = "pdf")]

use std::fs;
use std::path::PathBuf;

use pagetriage_core::structural::account_pdf_streams;

fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/golden")
}

fn fixtures() -> Vec<(String, PathBuf)> {
    let mut found = Vec::new();
    for dir in ["pdf", "streams_inputs"] {
        let path = golden_dir().join(dir);
        let entries = fs::read_dir(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        for e in entries {
            let p = e.unwrap().path();
            if p.extension().is_some_and(|x| x == "pdf") {
                found.push((p.file_stem().unwrap().to_string_lossy().into_owned(), p));
            }
        }
    }
    found.sort();
    found
}

#[test]
fn golden_stream_reports_match_byte_for_byte() {
    let update = std::env::var_os("UPDATE_GOLDEN").is_some();
    let expected_dir = golden_dir().join("streams");
    fs::create_dir_all(&expected_dir).unwrap();
    let all = fixtures();
    assert!(
        all.len() >= 14,
        "expected the 8 structure PDFs and at least 6 seeds, found {}",
        all.len()
    );
    let names: Vec<&String> = all.iter().map(|(n, _)| n).collect();
    let mut unique = names.clone();
    unique.dedup();
    assert_eq!(
        names, unique,
        "fixture names must be unique across both folders"
    );
    for (name, path) in all {
        let size = fs::metadata(&path).unwrap().len();
        assert!(
            size < 100 * 1024,
            "{name} is {size} bytes; fixtures stay under 100 KB"
        );
        let actual = format!(
            "{}\n",
            account_pdf_streams(&fs::read(&path).unwrap(), None).unwrap()
        );
        let expected_path = expected_dir.join(format!("{name}.json"));
        if update {
            fs::write(&expected_path, &actual).unwrap();
            continue;
        }
        let expected = fs::read_to_string(&expected_path).unwrap_or_else(|_| {
            panic!(
                "missing {}; run with UPDATE_GOLDEN=1",
                expected_path.display()
            )
        });
        assert_eq!(actual, expected, "golden mismatch for {name}");
    }
}

#[test]
fn the_seeds_cover_every_refusal_reason_a_small_file_can_give() {
    let want = [
        ("seed_font_bomb", "font_over_limit"),
        ("seed_content_bomb", "content_over_limit"),
        ("seed_unreferenced_bomb", "other_over_limit"),
        ("seed_image_raster", "image_over_limit"),
        ("seed_jpeg_sof", "image_over_limit"),
        ("seed_xref_broken", "unaccounted"),
        ("seed_chains_ok", ""),
    ];
    for (name, reason) in want {
        let path = golden_dir()
            .join("streams_inputs")
            .join(format!("{name}.pdf"));
        let json = account_pdf_streams(
            &fs::read(&path).unwrap_or_else(|e| panic!("{name}: {e}")),
            None,
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["reason"], reason, "{name}: {json}");
        assert_eq!(
            v["verdict"],
            if reason.is_empty() { "ok" } else { "refuse" },
            "{name}"
        );
    }
}
