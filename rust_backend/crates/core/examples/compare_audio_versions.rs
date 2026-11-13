//! Host parity harness for the same native entry point used on Android.
fn main() {
    let paths: Vec<_> = std::env::args().skip(1).collect();
    if paths.len() != 2 {
        eprintln!("usage: compare_audio_versions A.f32le B.f32le (mono 16000 Hz)");
        std::process::exit(2);
    }
    match mornye_core::audio_version_comparison::compare_files(&paths[0], &paths[1], &|| Ok(())) {
        Ok(result) => println!("{}", serde_json::to_string(&result).unwrap()),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
