//! One server-owned download. The C++ service starts this process with a trusted
//! request file; each account has separate packages, settings and encryption key.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use mornye_extensions::RuntimeLimits;
use mornye_extensions::backend::Backend;
use mornye_extensions::ffmpeg::CommandResult;
use mornye_extensions::package::ExtensionPackage;
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn text<'a>(value: &'a Value, name: &str) -> Result<&'a str> {
    value[name]
        .as_str()
        .ok_or_else(|| format!("missing {name}").into())
}

fn master_key(root: &Path) -> Result<String> {
    let path = root.join("master.key");
    if path.exists() {
        return Ok(fs::read_to_string(path)?);
    }
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes)?;
    let key = STANDARD.encode(bytes);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(key.as_bytes())?;
    file.sync_all()?;
    Ok(key)
}

fn execute(spec: Value) -> Result<Value> {
    let root = PathBuf::from(text(&spec, "user_root")?);
    fs::create_dir_all(&root)?;
    let output = fs::canonicalize(text(&spec, "output_dir")?)?;
    let backend = Backend::new(
        &root.join("sources"),
        &root.join("runtime"),
        &master_key(&root)?,
        "5.3.1",
        RuntimeLimits::default(),
    )?;
    backend.environment().set_allow_private_network(false)?;
    backend
        .environment()
        .set_allowed_download_directories(std::slice::from_ref(&output))?;
    backend.load_all()?;
    let package_path = Path::new(text(&spec, "package")?);
    let package = ExtensionPackage::open(package_path)?;
    let provider = text(&spec, "provider_id")?;
    if package.manifest.name != provider {
        return Err("package and provider do not match".into());
    }
    let installed_manifest = root.join("sources").join(provider).join("manifest.json");
    let same_version = fs::read_to_string(&installed_manifest)
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .is_some_and(|manifest| manifest["version"] == package.manifest.version);
    if !same_version {
        backend.install(package_path)?;
    }
    backend.set_enabled(provider, true)?;
    if let Some(path) = spec["settings_file"]
        .as_str()
        .filter(|path| !path.is_empty())
    {
        let settings: serde_json::Map<String, Value> =
            serde_json::from_str(&fs::read_to_string(path)?)?;
        // Merge operator-provided settings without erasing persisted auth state.
        for (key, value) in settings {
            if !key.starts_with('_') {
                backend.environment().set_setting(provider, &key, value)?;
            }
        }
    }
    let registry = backend.environment().ffmpeg_commands();
    let running = Arc::new(AtomicBool::new(true));
    let active = Arc::clone(&running);
    let pump = std::thread::spawn(move || {
        while active.load(Ordering::Acquire) {
            let Ok(raw) = registry.wait_pending_json(200) else {
                break;
            };
            let Ok(commands) = serde_json::from_str::<Vec<Value>>(&raw) else {
                continue;
            };
            for command in commands {
                let args: Vec<_> = command["arguments"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .collect();
                let status = Command::new("ffmpeg")
                    .arg("-nostdin")
                    .args(args)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
                let success = status.is_ok_and(|status| status.success());
                let _ = registry.complete(
                    command["command_id"].as_str().unwrap_or(""),
                    CommandResult {
                        success,
                        output: String::new(),
                        error: if success {
                            String::new()
                        } else {
                            "Server FFmpeg failed".into()
                        },
                    },
                );
            }
        }
    });
    let request = json!({
        "use_extensions": true, "use_fallback": false,
        "download_provider": provider, "service": provider, "source": provider,
        "provider_track_id": text(&spec, "track_id")?, "quality": text(&spec, "quality")?,
        "item_id": text(&spec, "item_id")?, "output_dir": output,
        "output_path": output.join("provider.audio"), "filename_format": "{title}",
        "track_name": spec["title"].as_str().unwrap_or(""),
        "artist_name": spec["artist"].as_str().unwrap_or(""), "embed_metadata": false
    });
    let response = backend.download_by_strategy(&request.to_string(), &|| Ok(()));
    running.store(false, Ordering::Release);
    let _ = pump.join();
    let response: Value = serde_json::from_str(&response?)?;
    if response["success"] != true {
        return Err(
            "extension download failed (check account settings and runtime support)".into(),
        );
    }
    let mut file = fs::canonicalize(text(&response, "file_path")?)?;
    if !file.is_file() {
        return Err("provider output is not a file".into());
    }
    file.strip_prefix(&output)?;
    if let Some(descriptor) = response.get("decryption").filter(|v| !v.is_null()) {
        if descriptor["strategy"] != "ffmpeg.mov_key" {
            return Err("unsupported provider decryption strategy".into());
        }
        let raw = text(descriptor, "key")?.trim().trim_start_matches("0x");
        let key = if raw.len() == 32 && raw.bytes().all(|c| c.is_ascii_hexdigit()) {
            raw.to_owned()
        } else {
            let bytes = STANDARD.decode(raw)?;
            if bytes.len() != 16 {
                return Err("invalid provider key".into());
            }
            bytes.iter().map(|byte| format!("{byte:02x}")).collect()
        };
        let decrypted = output.join("decrypted.flac");
        let status = Command::new("ffmpeg")
            .args([
                "-nostdin",
                "-v",
                "error",
                "-xerror",
                "-protocol_whitelist",
                "file,pipe",
                "-decryption_key",
                &key,
                "-f",
                "mov",
                "-i",
            ])
            .arg(&file)
            .args(["-map", "0:a:0", "-vn", "-c:a", "flac", "-y"])
            .arg(&decrypted)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        if !status.success() {
            return Err("provider decryption failed".into());
        }
        file = decrypted;
    }
    let relative = file.strip_prefix(&output)?;
    Ok(json!({"file": relative}))
}

fn main() {
    // Only the last JSON result reaches stdout. Extension logging stays inside
    // its runtime; credentials and provider URLs are never printed here.
    let result = (|| -> Result<Value> {
        let path = std::env::args_os()
            .nth(1)
            .ok_or("expected a request file")?;
        let raw = fs::read(path)?;
        if raw.len() > 64 * 1024 {
            return Err("request is too large".into());
        }
        execute(serde_json::from_slice(&raw)?)
    })();
    match result {
        Ok(value) => println!("{value}"),
        Err(_) => {
            eprintln!("Extension worker failed");
            std::process::exit(1);
        }
    }
}
