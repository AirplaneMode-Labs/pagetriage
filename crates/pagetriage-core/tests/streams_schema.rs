//! The JSON Schema of the stream-accounting report (`pagetriage.streams/0.1`) is generated from the
//! Rust types and checked in. Regenerate after changing the types in `structural/types.rs`:
//! `UPDATE_SCHEMA=1 cargo test -p pagetriage-core --test streams_schema`

use std::fs;
use std::path::PathBuf;

use pagetriage_core::schema::streams_schema_json;

fn schema_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../schema/pagetriage-streams-0.1.schema.json")
}

#[test]
fn checked_in_streams_schema_matches_the_rust_types() {
    let generated = streams_schema_json();
    if std::env::var_os("UPDATE_SCHEMA").is_some() {
        fs::write(schema_path(), &generated).unwrap();
        return;
    }
    let on_disk = fs::read_to_string(schema_path())
        .expect("schema/pagetriage-streams-0.1.schema.json is missing; run with UPDATE_SCHEMA=1");
    assert_eq!(
        on_disk, generated,
        "streams schema is stale; regenerate with `UPDATE_SCHEMA=1 cargo test -p pagetriage-core --test streams_schema`"
    );
}

#[cfg(feature = "pdf")]
#[test]
fn reports_validate_against_the_schema() {
    use pagetriage_core::structural::account_pdf_streams;
    let schema: serde_json::Value = serde_json::from_str(&streams_schema_json()).unwrap();
    let validator = jsonschema::validator_for(&schema).expect("schema is valid");
    let golden = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/golden");
    let mut checked = 0;
    for dir in ["pdf", "streams_inputs"] {
        for e in fs::read_dir(golden.join(dir)).unwrap() {
            let p = e.unwrap().path();
            if p.extension().is_some_and(|x| x == "pdf") {
                let json = account_pdf_streams(&fs::read(&p).unwrap(), None).unwrap();
                let doc: serde_json::Value = serde_json::from_str(&json).unwrap();
                let errors: Vec<String> =
                    validator.iter_errors(&doc).map(|e| e.to_string()).collect();
                assert!(errors.is_empty(), "{}: {errors:?}\n{json}", p.display());
                checked += 1;
            }
        }
    }
    assert!(checked >= 14);
}
