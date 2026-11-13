//! Exact numeric WavLM layer-6 preparation and conservative context verifier.
//! Model inference remains in the local runtime. No audio leaves the device.
use crate::audio_version_comparison::{MAX_BYTES, MAX_SECONDS};
use crate::audio_version_spectral::{Check, RATE, extract, median, smooth};
use crate::native_audio_analysis::read_bounded;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
};

pub const WAVLM_SHA256: &str = "594a8aa0be7b036a14ac8b8d15e588b0f388295fbc026bc2acaed6ae983205eb";
pub const CLIP_SAMPLES: usize = RATE * 12;
pub const FRAMES: usize = 599;
pub const CHANNELS: usize = 768;
const EMBEDDING_BYTES: usize = FRAMES * CHANNELS * 4;
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Event {
    pub start_b: f64,
    pub end_b: f64,
}
#[derive(Debug, Serialize)]
pub struct VerifiedEvent {
    pub start_b: f64,
    pub end_b: f64,
    pub context_start_b: f64,
    pub baseline_p95: Option<f64>,
    pub content_peak: Option<f64>,
    pub content_median: Option<f64>,
    pub normalized_peak_excess: Option<f64>,
    pub confirmed: bool,
}
#[derive(Debug, Serialize)]
pub struct Verification {
    pub model_sha256: &'static str,
    pub status: &'static str,
    pub events: Vec<VerifiedEvent>,
    pub preferred_side: Option<&'static str>,
    pub absolute_uncensored_status: &'static str,
}
fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn read_clip(path: &str, start: f64, check: Check<'_>) -> Result<Vec<f32>, String> {
    if !start.is_finite() || start.abs() > MAX_SECONDS as f64 {
        return Err("Invalid WavLM context time".into());
    }
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let stat = file.metadata().map_err(|e| e.to_string())?;
    if !stat.is_file() || stat.len() > MAX_BYTES as u64 || stat.len() % 4 != 0 {
        return Err("Invalid comparison PCM input".into());
    }
    let samples = (stat.len() / 4) as usize;
    let first = ((start * RATE as f64).floor().max(0.0) as usize).min(samples);
    let last = (((start + 12.0) * RATE as f64).ceil().max(0.0) as usize)
        .saturating_add(1)
        .min(samples)
        .max(first);
    let mut bytes = vec![0; (last - first) * 4];
    file.seek(SeekFrom::Start((first * 4) as u64))
        .map_err(|e| e.to_string())?;
    for chunk in bytes.chunks_mut(65536) {
        check()?;
        file.read_exact(chunk).map_err(|e| e.to_string())?;
    }
    let mut audio = Vec::with_capacity(bytes.len() / 4);
    for word in bytes.as_chunks::<4>().0.iter() {
        let value = f32::from_le_bytes(*word);
        if !value.is_finite() {
            return Err("Non-finite comparison PCM".into());
        }
        audio.push(value);
    }
    Ok(extract(&audio, start - first as f64 / RATE as f64, 12.0))
}
#[cfg(test)]
fn prepare_clip(
    path: &str,
    start: f64,
    output: &str,
    check: Check<'_>,
) -> Result<serde_json::Value, String> {
    prepare_clip_impl(path, start, output, true, check)
}
/// Padded raw samples; the Android inference boundary owns normalization.
pub fn prepare_raw_clip(
    path: &str,
    start: f64,
    output: &str,
    check: Check<'_>,
) -> Result<serde_json::Value, String> {
    prepare_clip_impl(path, start, output, false, check)
}
fn prepare_clip_impl(
    path: &str,
    start: f64,
    output: &str,
    normalize: bool,
    check: Check<'_>,
) -> Result<serde_json::Value, String> {
    check()?;
    let mut clip = read_clip(path, start, check)?;
    if normalize {
        let mean = clip.iter().map(|&x| x as f64).sum::<f64>() / CLIP_SAMPLES as f64;
        let variance =
            clip.iter().map(|&x| (x as f64 - mean).powi(2)).sum::<f64>() / CLIP_SAMPLES as f64;
        let scale = (variance + 1e-7).sqrt();
        for (i, x) in clip.iter_mut().enumerate() {
            if i % 65536 == 0 {
                check()?;
            }
            *x = ((*x as f64 - mean) / scale) as f32;
        }
    }
    let bytes: Vec<_> = clip.iter().flat_map(|x| x.to_le_bytes()).collect();
    let parent = Path::new(output)
        .parent()
        .ok_or("Missing context output directory")?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    for chunk in bytes.chunks(65536) {
        check()?;
        temp.write_all(chunk).map_err(|e| e.to_string())?;
    }
    check()?;
    temp.persist_noclobber(output).map_err(|e| e.to_string())?;
    Ok(
        serde_json::json!({"normalization": if normalize { "prepared" } else { "runtime" },"model_sha256":WAVLM_SHA256,"input_sha256":digest(&bytes),"sample_rate":RATE,"samples":CLIP_SAMPLES,"dtype":"float32","shape":[1,CLIP_SAMPLES]}),
    )
}
fn embeddings(path: &str, check: Check<'_>) -> Result<Vec<f64>, String> {
    let bytes = read_bounded(path, EMBEDDING_BYTES, check)?;
    if bytes.len() != EMBEDDING_BYTES {
        return Err("WavLM output must have shape [1,599,768] float32".into());
    }
    let mut values = Vec::with_capacity(FRAMES * CHANNELS);
    for word in bytes.as_chunks::<4>().0.iter() {
        let value = f32::from_le_bytes(*word);
        if !value.is_finite() {
            return Err("Non-finite WavLM embedding".into());
        }
        values.push(value as f64);
    }
    normalize_embeddings(&mut values, check)?;
    Ok(values)
}
fn normalize_embeddings(values: &mut [f64], check: Check<'_>) -> Result<(), String> {
    for row in values.as_chunks_mut::<CHANNELS>().0 {
        check()?;
        let norm = row.iter().map(|x| x * x).sum::<f64>().sqrt().max(1e-9);
        for x in row {
            *x /= norm;
        }
    }
    Ok(())
}
fn scores(a: &[f64], b: &[f64], check: Check<'_>) -> Result<Vec<f64>, String> {
    let dot = |i: usize, j: usize| {
        a[i * CHANNELS..(i + 1) * CHANNELS]
            .iter()
            .zip(&b[j * CHANNELS..(j + 1) * CHANNELS])
            .map(|(a, b)| a * b)
            .sum::<f64>()
    };
    let mut forward = vec![0.0; FRAMES];
    let mut reverse = vec![0.0; FRAMES];
    for i in 0..FRAMES {
        check()?;
        let d = (1.0 - dot(i, i)).max(0.0);
        forward[i] = d;
        reverse[i] = d;
    }
    for i in 0..FRAMES - 1 {
        check()?;
        let d = (1.0 - dot(i, i + 1)).max(0.0);
        forward[i] = forward[i].min(d);
        reverse[i + 1] = reverse[i + 1].min(d);
        let d = (1.0 - dot(i + 1, i)).max(0.0);
        forward[i + 1] = forward[i + 1].min(d);
        reverse[i] = reverse[i].min(d);
    }
    Ok(smooth(
        &forward
            .iter()
            .zip(reverse)
            .map(|(a, b)| (a + b) / 2.0)
            .collect::<Vec<_>>(),
        3,
    ))
}
fn percentile95(values: &[f64]) -> f64 {
    let mut v = values.to_vec();
    v.sort_by(f64::total_cmp);
    let p = (v.len() - 1) as f64 * 0.95;
    let lo = p.floor() as usize;
    let hi = p.ceil() as usize;
    v[lo] + (v[hi] - v[lo]) * (p - lo as f64)
}
fn validate_events(events: &[Event]) -> Result<(), String> {
    if events.len() > 10000 {
        return Err("Too many content events".into());
    }
    for e in events {
        if !e.start_b.is_finite()
            || !e.end_b.is_finite()
            || e.start_b < 0.0
            || e.end_b <= e.start_b
            || e.end_b > MAX_SECONDS as f64
        {
            return Err("Invalid content event".into());
        }
    }
    Ok(())
}
fn verify_scores(score: &[f64], start: f64, events: &[Event], all: &[Event]) -> Verification {
    let time = |i: usize| i as f64 * 0.02 + 0.0125 + start;
    let outside: Vec<_> = score
        .iter()
        .enumerate()
        .filter(|(i, _)| {
            all.iter()
                .all(|e| time(*i) < e.start_b - 0.25 || time(*i) > e.end_b + 0.25)
        })
        .map(|(_, s)| *s)
        .collect();
    let baseline = (outside.len() >= 50).then(|| percentile95(&outside));
    let mut rows = Vec::new();
    for e in events {
        let values: Vec<_> = score
            .iter()
            .enumerate()
            .filter(|(i, _)| time(*i) >= e.start_b - 0.04 && time(*i) <= e.end_b + 0.04)
            .map(|(_, s)| *s)
            .collect();
        let peak =
            (!values.is_empty()).then(|| values.iter().copied().fold(f64::NEG_INFINITY, f64::max));
        let med = (!values.is_empty()).then(|| median(&values));
        let normalized = match (peak, baseline) {
            (Some(p), Some(b)) if b < 0.7 => Some((p - b) / (1.0 - b)),
            _ => None,
        };
        let confirmed = match (peak, med, baseline, normalized) {
            (Some(p), Some(m), Some(b), Some(r)) => m - b >= 0.05 && (p - b >= 0.55 || r >= 0.65),
            _ => false,
        };
        rows.push(VerifiedEvent {
            start_b: e.start_b,
            end_b: e.end_b,
            context_start_b: start,
            baseline_p95: baseline,
            content_peak: peak,
            content_median: med,
            normalized_peak_excess: normalized,
            confirmed,
        });
    }
    let status = if rows.iter().any(|e| e.confirmed) {
        "confirmed_content_change"
    } else if baseline.is_none_or(|b| b >= 0.7) {
        "verification_uncertain"
    } else {
        "no_confirmed_content_change"
    };
    Verification {
        model_sha256: WAVLM_SHA256,
        status,
        events: rows,
        preferred_side: None,
        absolute_uncensored_status: "unknown",
    }
}
pub fn verify_context(
    path_a: &str,
    path_b: &str,
    start: f64,
    events: &[Event],
    all: &[Event],
    model_sha: &str,
    check: Check<'_>,
) -> Result<Verification, String> {
    if model_sha != WAVLM_SHA256 {
        return Err("Unsupported WavLM model digest".into());
    }
    if !start.is_finite() || start < 0.0 || start > MAX_SECONDS as f64 {
        return Err("Invalid content context".into());
    }
    validate_events(events)?;
    validate_events(all)?;
    // Every selected event must also be excluded from the outside baseline.
    if events.iter().any(|e| {
        !all.iter()
            .any(|a| a.start_b <= e.start_b && a.end_b >= e.end_b)
    }) {
        return Err("Selected event missing from baseline exclusions".into());
    }
    let a = embeddings(path_a, check)?;
    let b = embeddings(path_b, check)?;
    let score = scores(&a, &b, check)?;
    check()?;
    Ok(verify_scores(&score, start, events, all))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn wavlm_audio() -> Vec<f32> {
        (0..CLIP_SAMPLES)
            .map(|i| {
                let u = (i as u32 + 1)
                    .wrapping_mul(1664525)
                    .wrapping_add(1013904223) as f64
                    / 4294967296.0;
                (0.15 * (2.0 * std::f64::consts::PI * 220.0 * i as f64 / RATE as f64).sin()
                    + 0.10 * (2.0 * std::f64::consts::PI * 659.25 * i as f64 / RATE as f64).sin()
                    + 0.025 * (2.0 * u - 1.0)) as f32
            })
            .collect()
    }
    fn write_pcm(path: &Path, audio: &[f32]) {
        let bytes: Vec<_> = audio.iter().flat_map(|x| x.to_le_bytes()).collect();
        std::fs::write(path, bytes).unwrap();
    }
    #[test]
    fn runtime_clip_preserves_raw_amplitude_and_zero_padding() {
        let tmp = tempfile::tempdir().unwrap();
        let input = tmp.path().join("input.pcm");
        let output = tmp.path().join("raw.pcm");
        write_pcm(&input, &vec![0.25; RATE]);
        let result = prepare_raw_clip(
            input.to_str().unwrap(),
            -1.0,
            output.to_str().unwrap(),
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(result["normalization"], "runtime");
        let bytes = std::fs::read(&output).unwrap();
        let values: Vec<_> = bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|v| f32::from_le_bytes(*v))
            .collect();
        assert_eq!(values.len(), CLIP_SAMPLES);
        assert!(values[..RATE].iter().all(|v| *v == 0.0));
        assert!(values[RATE..RATE * 2].iter().all(|v| *v == 0.25));
        assert!(values[RATE * 2..].iter().all(|v| *v == 0.0));
    }
    #[test]
    fn normalization_matches_exporter_golden_without_bundled_model() {
        let golden: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/audio_version_wavlm_golden.json"
        ))
        .unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let a = wavlm_audio();
        for case in golden["cases"].as_array().unwrap() {
            let mut raw = a.clone();
            if case["role"] == "B" {
                for x in &mut raw {
                    *x *= 0.7;
                }
                raw[81600..87200].fill(0.0);
            }
            let input = tmp.path().join("input.pcm");
            let output = tmp
                .path()
                .join(format!("{}-normalized.pcm", case["role"].as_str().unwrap()));
            write_pcm(&input, &raw);
            let metadata = prepare_clip(
                input.to_str().unwrap(),
                0.0,
                output.to_str().unwrap(),
                &|| Ok(()),
            )
            .unwrap();
            assert_eq!(metadata["samples"], CLIP_SAMPLES);
            assert_eq!(metadata["model_sha256"], WAVLM_SHA256);
            let bytes = std::fs::read(&output).unwrap();
            assert_eq!(bytes.len(), CLIP_SAMPLES * 4);
            for point in case["normalization_samples"].as_array().unwrap() {
                let i = point["index"].as_u64().unwrap() as usize;
                let actual = f32::from_le_bytes(bytes[i * 4..i * 4 + 4].try_into().unwrap()) as f64;
                assert!(
                    (actual - point["normalized"].as_f64().unwrap()).abs() < 1e-5,
                    "role{} sample{i}: {actual}",
                    case["role"]
                );
            }
        }
    }
    #[test]
    fn padding_is_included_in_normalization_and_outputs_never_overwrite() {
        let tmp = tempfile::tempdir().unwrap();
        let input = tmp.path().join("input.pcm");
        let output = tmp.path().join("output.pcm");
        write_pcm(&input, &vec![1.0; RATE]);
        prepare_clip(
            input.to_str().unwrap(),
            -1.0,
            output.to_str().unwrap(),
            &|| Ok(()),
        )
        .unwrap();
        let bytes = std::fs::read(&output).unwrap();
        let padded = f32::from_le_bytes(bytes[..4].try_into().unwrap());
        assert!(padded < 0.0);
        let original = std::fs::read(&input).unwrap();
        assert!(
            prepare_clip(
                input.to_str().unwrap(),
                0.0,
                input.to_str().unwrap(),
                &|| Ok(())
            )
            .is_err()
        );
        assert_eq!(std::fs::read(&input).unwrap(), original);
        let cancelled = tmp.path().join("cancelled.pcm");
        let calls = std::cell::Cell::new(0);
        let result = prepare_clip(
            input.to_str().unwrap(),
            0.0,
            cancelled.to_str().unwrap(),
            &|| {
                calls.set(calls.get() + 1);
                if calls.get() > 7 {
                    Err("cancelled".into())
                } else {
                    Ok(())
                }
            },
        );
        assert!(result.is_err());
        assert!(!cancelled.exists());
    }
    fn embedding_pair() -> (Vec<f64>, Vec<f64>) {
        let mut a = vec![0.0; FRAMES * CHANNELS];
        for row in 0..FRAMES {
            for channel in 0..CHANNELS {
                let mut value = (row as u32 + 1).wrapping_mul(2246822519)
                    ^ (channel as u32 + 7).wrapping_mul(3266489917);
                value ^= value >> 13;
                value = value.wrapping_mul(668265263);
                a[row * CHANNELS + channel] =
                    ((value & 65535) as f64 / 32768.0 - 1.0) as f32 as f64;
            }
        }
        let mut b: Vec<_> = a.iter().map(|&x| ((x as f32) * 0.7_f32) as f64).collect();
        for row in 80..120 {
            for c in 0..CHANNELS {
                b[row * CHANNELS + c] = ((a[(row + 1) * CHANNELS + c] as f32) * 0.7_f32) as f64;
            }
        }
        b[240 * CHANNELS..260 * CHANNELS].fill(0.0);
        for x in &mut b[310 * CHANNELS..318 * CHANNELS] {
            *x = ((*x as f32) + 0.025_f32) as f64;
        }
        for row in 420..435 {
            for c in 0..CHANNELS {
                b[row * CHANNELS + c] = ((a[(row - 400) * CHANNELS + c] as f32) * 0.7_f32) as f64;
            }
        }
        (a, b)
    }
    #[test]
    fn symmetric_content_scores_and_decisions_match_numpy_golden() {
        let golden: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/audio_version_content_golden.json"
        ))
        .unwrap();
        let (mut a, mut b) = embedding_pair();
        normalize_embeddings(&mut a, &|| Ok(())).unwrap();
        normalize_embeddings(&mut b, &|| Ok(())).unwrap();
        let score = scores(&a, &b, &|| Ok(())).unwrap();
        for point in golden["selected_scores"].as_array().unwrap() {
            let i = point["frame"].as_u64().unwrap() as usize;
            assert!(
                (score[i] - point["score"].as_f64().unwrap()).abs() < 2e-5,
                "frame{i}: {} vs {}",
                score[i],
                point["score"]
            );
        }
        let events: Vec<_> = golden["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| Event {
                start_b: e["start_B"].as_f64().unwrap(),
                end_b: e["end_B"].as_f64().unwrap(),
            })
            .collect();
        let result = verify_scores(&score, 0.0, &events, &events);
        assert_eq!(result.status, "confirmed_content_change");
        for (actual, want) in result
            .events
            .iter()
            .zip(golden["events"].as_array().unwrap())
        {
            assert_eq!(actual.confirmed, want["confirmed"].as_bool().unwrap());
            assert!(
                (actual.baseline_p95.unwrap() - golden["baseline_p95"].as_f64().unwrap()).abs()
                    < 2e-5
            );
            assert!((actual.content_peak.unwrap() - want["peak"].as_f64().unwrap()).abs() < 2e-5);
            assert!(
                (actual.content_median.unwrap() - want["median"].as_f64().unwrap()).abs() < 2e-5
            );
        }
        assert!(result.preferred_side.is_none());
        assert_eq!(result.absolute_uncensored_status, "unknown");
    }
    #[test]
    fn missing_baseline_and_invalid_models_do_not_confirm_changes() {
        let event = Event {
            start_b: 0.0,
            end_b: 12.0,
        };
        let r = verify_scores(
            &vec![1.0; FRAMES],
            0.0,
            std::slice::from_ref(&event),
            std::slice::from_ref(&event),
        );
        assert_eq!(r.status, "verification_uncertain");
        assert!(!r.events[0].confirmed);
        assert!(
            verify_context("absent", "absent", 0.0, &[], &[], "other-model", &|| Ok(())).is_err()
        );
        assert!(
            verify_context(
                "absent",
                "absent",
                0.0,
                &[event],
                &[],
                WAVLM_SHA256,
                &|| Ok(())
            )
            .unwrap_err()
            .contains("baseline")
        );
    }
}
