//! Host numeric validation driver; uses the exact same functions as Android jobs.
use mornye_core::audio_version_demucs as d;
use sha2::{Digest, Sha256};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let request: serde_json::Value = serde_json::from_slice(&std::fs::read(
        std::env::args().nth(1).ok_or("request path")?,
    )?)?;
    let path = |key: &str| request[key].as_str().unwrap();
    let check = &|| Ok(());
    let output = match path("action") {
        "metadata" => {
            serde_json::json!({"rust_source_sha256": mornye_core::lower_hex(&Sha256::digest(include_bytes!("../src/audio_version_demucs.rs")))})
        }
        "prepare" => d::prepare(
            path("input"),
            request["offset"].as_u64().unwrap() as usize,
            path("wave"),
            path("spec"),
            check,
        )?,
        "finish" => {
            d::finish(path("freq"), path("time"), path("output"), check)?;
            serde_json::json!({})
        }
        "merge" => {
            let chunks: Vec<String> = serde_json::from_value(request["chunks"].clone())?;
            d::merge(
                &chunks,
                request["samples"].as_u64().unwrap() as usize,
                request["mean"].as_f64().unwrap(),
                request["std"].as_f64().unwrap(),
                path("output"),
                check,
            )?;
            serde_json::json!({})
        }
        _ => return Err("unknown action".into()),
    };
    println!("{output}");
    Ok(())
}
