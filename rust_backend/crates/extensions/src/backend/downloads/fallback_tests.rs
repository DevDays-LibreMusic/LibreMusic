use super::*;
use crate::RuntimeLimits;
use base64::Engine;

struct Fixture {
    backend: Backend,
    output: std::path::PathBuf,
    _directory: tempfile::TempDir,
}

impl Fixture {
    fn new(
        availability: &str,
        direct_download: &str,
        returned: Value,
        account: bool,
        locked: bool,
    ) -> Self {
        Self::with_metadata(
            availability,
            direct_download,
            returned,
            account,
            locked,
            None,
        )
    }

    fn with_metadata(
        availability: &str,
        direct_download: &str,
        returned: Value,
        account: bool,
        locked: bool,
        metadata: Option<Value>,
    ) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let sources = directory.path().join("sources");
        let encoded = base64::engine::general_purpose::STANDARD.encode(b"ID3example audio");
        for id in ["soundcloud", "example.fallback"] {
            let source = sources.join(id);
            std::fs::create_dir_all(&source).unwrap();
            let mut manifest = json!({"name":id,"version":"1","type":["download_provider"],
                "description":"Scoped recording fallback fixture","permissions":{"file":true,"storage":true},
                "skipMetadataEnrichment":true});
            if id == "soundcloud" {
                manifest["type"] = json!(["metadata_provider", "download_provider"]);
                if account {
                    manifest["capabilities"] =
                        json!({"accountDownloadMode":{"setting":"mode","value":"personal"}});
                }
                if locked {
                    manifest["stopProviderFallback"] = true.into();
                }
            } else {
                // Even a provider requesting custom matching may not publish a
                // different recording through the new scoped cross-source path.
                manifest["trackMatching"] = json!({"customMatching":true});
                manifest["capabilities"] =
                    json!({"accountDownloadMode":{"setting":"mode","value":"personal"}});
                if metadata.is_some() {
                    manifest["type"] = json!(["metadata_provider", "download_provider"]);
                }
            }
            std::fs::write(source.join("manifest.json"), manifest.to_string()).unwrap();
            let (check_body, download_body) = if id == "soundcloud" {
                (availability.to_owned(), direct_download.to_owned())
            } else {
                (
                    "return {available:true,track_id:'fallback-track'};".to_owned(),
                    format!(
                        "const path=outputPath.replace(/\\.[^.]+$/,'.mp3'); file.writeBytes(path,{encoded}); const result={returned}; result.success=true; result.file_path=path; result.actual_extension='mp3'; return result;",
                        encoded = json!(encoded),
                        returned = returned
                    ),
                )
            };
            let lookup = if id == "example.fallback" {
                metadata
                    .as_ref()
                    .map(|track| {
                        if let Some(error) = track["lookup_error"].as_str() {
    format!("getTrack(){{throw new Error({});}},", json!(error))
} else { format!("getTrack(id){{if(id!=='fallback-track') throw new Error('wrong lookup ID'); storage.set('lookup',id);return {track};}},") }
                    })
                    .unwrap_or_default()
            } else {
                String::new()
            };
            std::fs::write(source.join("index.js"), format!(
                "registerExtension({{{lookup}enrichTrack(track){{storage.set('enrichCalls',(storage.get('enrichCalls')||0)+1);return track;}},enrichmentCalls(){{return storage.get('enrichCalls')||0;}},checkAvailability(){{storage.set('checks',(storage.get('checks')||0)+1);{check_body}}},download(id,quality,outputPath){{storage.set('downloads',(storage.get('downloads')||0)+1);{download_body}}},stats(){{return {{checks:storage.get('checks')||0,downloads:storage.get('downloads')||0}};}}}});"
            )).unwrap();
        }
        let backend = Backend::new(
            &sources,
            &directory.path().join("data"),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "1",
            RuntimeLimits::default(),
        )
        .unwrap();
        backend.load_all().unwrap();
        for id in ["soundcloud", "example.fallback"] {
            backend.set_enabled(id, true).unwrap();
        }
        backend
            .set_provider_priority(
                "download",
                vec!["soundcloud".into(), "example.fallback".into()],
            )
            .unwrap();
        if account {
            backend
                .update_settings(
                    "soundcloud",
                    serde_json::from_value(json!({"mode":"personal"})).unwrap(),
                )
                .unwrap();
        }
        let output = directory.path().join("output");
        std::fs::create_dir_all(&output).unwrap();
        backend
            .environment()
            .set_allowed_download_directories(std::slice::from_ref(&output))
            .unwrap();
        Self {
            backend,
            output,
            _directory: directory,
        }
    }

    fn run(&self, selected: &str, fallback: bool) -> Value {
        let request = json!({"service":selected,"source":"soundcloud","spotify_id":"14156106",
            "provider_track_id":"14156106","item_id":"wave-fixture-1","isrc":"USAAA2600001",
            "track_name":"Song","artist_name":"Artist","album_name":"Album","duration_ms":180000,
            "quality":"best","output_dir":self.output,"filename_format":"{title}","output_ext":".mp3",
            "use_extensions":true,"use_fallback":fallback,"embed_metadata":false,"embed_lyrics":false});
        serde_json::from_str(
            &self
                .backend
                .download_by_strategy(&request.to_string(), &|| Ok(()))
                .unwrap(),
        )
        .unwrap()
    }

    fn add_third_provider(&self) {
        let source = self._directory.path().join("sources/example.third");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("manifest.json"),json!({"name":"example.third","version":"1",
            "type":["download_provider"],"description":"Terminal error sentinel","permissions":{"storage":true}}).to_string()).unwrap();
        std::fs::write(source.join("index.js"),"registerExtension({checkAvailability(){storage.set('checks',1); return {available:false,reason:'third called'};},stats(){return {checks:storage.get('checks')||0};}});").unwrap();
        self.backend.load_all().unwrap();
        self.backend.set_enabled("example.third", true).unwrap();
        self.backend
            .set_provider_priority(
                "download",
                vec![
                    "soundcloud".into(),
                    "example.fallback".into(),
                    "example.third".into(),
                ],
            )
            .unwrap();
    }

    fn stats(&self, id: &str) -> Value {
        serde_json::from_str(&self.backend.call(id, "stats", "[]", None, 1000).unwrap()).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.backend.shutdown();
    }
}

fn recording() -> Value {
    json!({"title":"Song","artist":"Artist","album":"Album","isrc":"USAAA2600001","duration_ms":180000})
}

const UNAVAILABLE: &str = "return {available:false,skip_fallback:true,fallback_scope:'provider',reason:'source stream unavailable'};";
const AVAILABLE: &str =
    "return {available:true,skip_fallback:true,fallback_scope:'provider',track_id:'14156106'};";
const FAILED_DOWNLOAD: &str =
    "return {success:false,error_message:'source stream unavailable',error_type:'api_error'};";

#[test]
fn wave_source_unavailable_tries_another_provider_and_publishes_matching_audio() {
    for selected in ["soundcloud", "example.fallback"] {
        let fixture = Fixture::new(
            UNAVAILABLE,
            "throw new Error('unavailable source must not download');",
            recording(),
            false,
            false,
        );
        let result = fixture.run(selected, true);
        assert_eq!(result["success"], true, "{selected}: {result}");
        assert_eq!(result["service"], "example.fallback", "{result}");
        assert_eq!(
            result["resolved_provider_id"], "example.fallback",
            "{result}"
        );
        assert_eq!(
            result["resolved_provider_track_id"], "fallback-track",
            "{result}"
        );
        assert_eq!(
            fixture.stats("soundcloud"),
            json!({"checks":1,"downloads":0})
        );
        assert_eq!(
            fixture.stats("example.fallback"),
            json!({"checks":1,"downloads":1})
        );
        let files = std::fs::read_dir(&fixture.output)
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(std::fs::read(files[0].path()).unwrap(), b"ID3example audio");
    }
}

#[test]
fn source_lookup_error_and_stream_failure_continue_without_rematching_source_id() {
    for availability in ["throw new Error('source API offline');", AVAILABLE] {
        let fixture = Fixture::new(availability, FAILED_DOWNLOAD, recording(), false, false);
        let result = fixture.run("soundcloud", true);
        assert_eq!(result["success"], true, "{result}");
        assert_eq!(fixture.stats("soundcloud")["checks"], 1);
        assert_eq!(
            fixture.stats("soundcloud")["downloads"],
            if availability == AVAILABLE { 1 } else { 0 }
        );
        assert_eq!(fixture.stats("example.fallback")["downloads"], 1);
    }
}

#[test]
fn scoped_fallback_rejects_wrong_recordings_even_when_provider_uses_custom_matching() {
    for bad in [
        json!({"title":"Other song","artist":"Artist","duration_ms":180000}),
        json!({"title":"Song (Live)","artist":"Artist","duration_ms":180000}),
        json!({"title":"Song","artist":"Cover artist","duration_ms":180000}),
        json!({"title":"Song","artist":"Artist","duration_ms":30000}),
        json!({"title":"Song","artist":"Artist","duration_ms":200000}),
        json!({"title":"Song","artist":"Artist","duration_ms":180000,"isrc":"USAAA2600002"}),
        json!({}),
    ] {
        let fixture = Fixture::new(UNAVAILABLE, FAILED_DOWNLOAD, bad.clone(), false, false);
        let result = fixture.run("soundcloud", true);
        assert_eq!(result["success"], false, "{bad}: {result}");
        assert!(
            text(&result, "error").contains("different track"),
            "{result}"
        );
        assert_eq!(fixture.stats("example.fallback")["downloads"], 1);
        assert_eq!(
            std::fs::read_dir(&fixture.output).unwrap().count(),
            0,
            "{bad}"
        );
    }
}

#[test]
fn recording_veto_missing_scope_and_unknown_scope_still_block_every_provider() {
    for scope in [None, Some("recording"), Some("invalid-scope")] {
        let mut value =
            json!({"available":false,"skip_fallback":true,"reason":"recording identity veto"});
        if let Some(scope) = scope {
            value["fallback_scope"] = scope.into();
        }
        let fixture = Fixture::new(
            &format!("return {value};"),
            FAILED_DOWNLOAD,
            recording(),
            false,
            false,
        );
        let result = fixture.run("example.fallback", true);
        assert_eq!(result["success"], false, "{result}");
        assert!(
            text(&result, "error").contains("Fallback stopped by soundcloud"),
            "{result}"
        );
        assert_eq!(
            fixture.stats("example.fallback"),
            json!({"checks":0,"downloads":0})
        );
    }
}

#[test]
fn scoped_failure_respects_account_mode_explicit_provider_lock_and_disabled_fallback() {
    for (account, locked, enabled) in [
        (true, false, true),
        (false, true, true),
        (false, false, false),
    ] {
        let fixture = Fixture::new(UNAVAILABLE, FAILED_DOWNLOAD, recording(), account, locked);
        let result = fixture.run("soundcloud", enabled);
        assert_eq!(result["success"], false, "{result}");
        assert_eq!(
            fixture.stats("example.fallback"),
            json!({"checks":0,"downloads":0})
        );
    }
    let fixture = Fixture::new(UNAVAILABLE, FAILED_DOWNLOAD, recording(), false, false);
    fixture
        .backend
        .set_fallback_providers(Some(vec![]))
        .unwrap();
    assert_eq!(fixture.run("soundcloud", true)["success"], false);
    assert_eq!(fixture.stats("example.fallback")["checks"], 0);
}

#[test]
fn optional_direct_availability_can_still_download_its_known_id() {
    let encoded = base64::engine::general_purpose::STANDARD.encode(b"ID3example audio");
    let fixture = Fixture::new(
        "return null;",
        &format!(
            "const path=outputPath.replace(/\\.[^.]+$/,'.mp3'); file.writeBytes(path,{encoded}); return {{success:true,file_path:path,actual_extension:'mp3'}};",
            encoded = json!(encoded)
        ),
        recording(),
        false,
        false,
    );
    let response = fixture.run("soundcloud", false);
    assert_eq!(response["success"], true, "{response}");
    assert_eq!(fixture.stats("example.fallback")["checks"], 0);
}

#[test]
fn metadata_light_download_uses_verified_target_lookup_not_expected_host_fields() {
    let target = json!({"id":"fallback-track","name":"Song","artists":"Artist","isrc":"USAAA2600001","duration_ms":180000});
    let fixture = Fixture::with_metadata(
        UNAVAILABLE,
        FAILED_DOWNLOAD,
        json!({}),
        false,
        false,
        Some(target),
    );
    let result = fixture.run("soundcloud", true);
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(fixture.stats("example.fallback")["downloads"], 1);
}

#[test]
fn target_lookup_rejects_other_id_or_recording_before_downloading() {
    for target in [
        json!({"id":"another-id","name":"Song","artists":"Artist","duration_ms":180000}),
        json!({"id":"fallback-track","name":"Song (Live)","artists":"Artist","duration_ms":180000}),
        json!({"id":"fallback-track","name":"Song","artists":"Cover artist","duration_ms":180000}),
        json!({"id":"fallback-track","name":"Song","artists":"Artist","duration_ms":30000}),
    ] {
        let fixture = Fixture::with_metadata(
            UNAVAILABLE,
            FAILED_DOWNLOAD,
            json!({}),
            false,
            false,
            Some(target.clone()),
        );
        let result = fixture.run("soundcloud", true);
        assert_eq!(result["success"], false, "{target}: {result}");
        assert_eq!(fixture.stats("example.fallback")["downloads"], 0);
        assert_eq!(std::fs::read_dir(&fixture.output).unwrap().count(), 0);
    }
}

#[test]
fn valid_lookup_does_not_overwrite_conflicting_download_identity() {
    let target =
        json!({"id":"fallback-track","name":"Song","artists":"Artist","duration_ms":180000});
    let fixture = Fixture::with_metadata(
        UNAVAILABLE,
        FAILED_DOWNLOAD,
        json!({"title":"Song (Live)"}),
        false,
        false,
        Some(target),
    );
    let result = fixture.run("soundcloud", true);
    assert_eq!(result["success"], false, "{result}");
    assert_eq!(std::fs::read_dir(&fixture.output).unwrap().count(), 0);
}

#[test]
fn existing_filename_cannot_bypass_scoped_recording_verification() {
    let fixture = Fixture::new(
        UNAVAILABLE,
        FAILED_DOWNLOAD,
        json!({"title":"Other song","artist":"Artist","duration_ms":180000}),
        false,
        false,
    );
    let old = fixture.output.join("Song.mp3");
    std::fs::write(&old, b"ID3preserve previous library file").unwrap();
    let response = fixture.run("soundcloud", true);
    assert_eq!(response["success"], false, "{response}");
    assert_eq!(fixture.stats("example.fallback")["downloads"], 1);
    assert_eq!(
        std::fs::read(&old).unwrap(),
        b"ID3preserve previous library file"
    );
}

#[test]
fn target_identity_lookup_preserves_verification_and_permission_stops() {
    for (error, kind) in [
        (
            "verification_required: extension needs signed-session verification",
            "verification_required",
        ),
        ("permission denied", "permission"),
    ] {
        let fixture = Fixture::with_metadata(
            UNAVAILABLE,
            FAILED_DOWNLOAD,
            json!({}),
            false,
            false,
            Some(json!({"lookup_error":error})),
        );
        fixture.add_third_provider();
        let response = fixture.run("soundcloud", true);
        assert_eq!(response["success"], false, "{response}");
        assert_eq!(response["error_type"], kind, "{response}");
        assert!(
            !text(&response, "error").contains("All providers failed"),
            "{response}"
        );
        assert_eq!(fixture.stats("example.fallback")["downloads"], 0);
        assert_eq!(fixture.stats("example.third")["checks"], 0);
    }
}

#[test]
fn unavailable_source_is_not_queried_again_for_optional_metadata_before_fallback() {
    let fixture = Fixture::new(UNAVAILABLE, FAILED_DOWNLOAD, recording(), false, false);
    let response = fixture.run("soundcloud", true);
    assert_eq!(response["success"], true, "{response}");
    assert_eq!(
        fixture
            .backend
            .call("soundcloud", "enrichmentCalls", "[]", None, 1000)
            .unwrap(),
        "0"
    );
    assert_eq!(fixture.stats("soundcloud")["checks"], 1);
}

#[test]
fn available_scoped_source_is_tried_first_even_when_another_service_is_default() {
    let encoded = base64::engine::general_purpose::STANDARD.encode(b"ID3source recording");
    let fixture = Fixture::new(
        AVAILABLE,
        &format!(
            "const path=outputPath.replace(/\\.[^.]+$/,'.mp3'); file.writeBytes(path,{encoded}); return {{success:true,file_path:path,actual_extension:'mp3'}};",
            encoded = json!(encoded)
        ),
        recording(),
        false,
        false,
    );
    let result = fixture.run("example.fallback", true);
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["service"], "soundcloud", "{result}");
    assert_eq!(result["resolved_provider_id"], "soundcloud", "{result}");
    assert_eq!(result["resolved_provider_track_id"], "14156106", "{result}");
    assert_eq!(
        fixture.stats("soundcloud"),
        json!({"checks":1,"downloads":1})
    );
    assert_eq!(
        fixture.stats("example.fallback"),
        json!({"checks":0,"downloads":0})
    );
}

#[test]
fn scoped_source_failure_then_uses_the_different_default_service_once() {
    let fixture = Fixture::new(AVAILABLE, FAILED_DOWNLOAD, recording(), false, false);
    let result = fixture.run("example.fallback", true);
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["service"], "example.fallback", "{result}");
    assert_eq!(
        fixture.stats("soundcloud"),
        json!({"checks":1,"downloads":1})
    );
    assert_eq!(
        fixture.stats("example.fallback"),
        json!({"checks":1,"downloads":1})
    );
}

#[test]
fn selected_personal_account_is_not_preempted_by_public_scoped_source() {
    let fixture = Fixture::new(
        AVAILABLE,
        "throw new Error('source must not preempt selected account');",
        recording(),
        false,
        false,
    );
    fixture
        .backend
        .update_settings(
            "example.fallback",
            serde_json::from_value(json!({"mode":"personal"})).unwrap(),
        )
        .unwrap();
    let result = fixture.run("example.fallback", true);
    assert_eq!(result["success"], true, "{result}");
    assert_eq!(result["service"], "example.fallback", "{result}");
    assert_eq!(
        fixture.stats("soundcloud"),
        json!({"checks":1,"downloads":0})
    );
    assert_eq!(
        fixture.stats("example.fallback"),
        json!({"checks":1,"downloads":1})
    );
}
