//! Local first stage of the censorship comparison. DSP candidates are never
//! confirmed censorship or grounds to select a source without learned evidence.
use crate::audio_version_alignment::{self, Alignment};
use crate::audio_version_spectral::*;
use crate::native_audio_analysis::read_bounded;
use serde::Serialize;
use sha2::{Digest, Sha256};

pub const VERSION: &str = "audio-version-dsp-v1";
pub const MAX_SECONDS: usize = 600;
pub const MAX_BYTES: usize = RATE * 4 * MAX_SECONDS;

#[derive(Debug, Serialize)]
pub struct Candidate {
    pub start_a: f64,
    pub end_a: f64,
    pub start_b: f64,
    pub end_b: f64,
    pub kind: &'static str,
    pub peak_score: f64,
}
#[derive(Debug, Serialize)]
pub struct Comparison {
    pub version: &'static str,
    pub status: &'static str,
    pub source_a_sha256: String,
    pub source_b_sha256: String,
    pub duration_a: f64,
    pub duration_b: f64,
    pub alignment: Alignment,
    pub shared_start_a: Option<f64>,
    pub shared_start_b: Option<f64>,
    pub shared_duration: Option<f64>,
    pub usable_bands: usize,
    pub candidates: Vec<Candidate>,
    pub preferred_side: Option<&'static str>,
    pub absolute_uncensored_status: &'static str,
}
fn decode(path: &str, check: Check<'_>) -> Result<(Vec<f32>, String), String> {
    let bytes = read_bounded(path, MAX_BYTES, check)?;
    if bytes.len() % 4 != 0 {
        return Err("Comparison PCM must be mono float32 little-endian".into());
    }
    if bytes.len() < RATE * 4 * 13 {
        return Err("Comparison needs at least thirteen seconds per recording".into());
    }
    let mut hash = Sha256::new();
    let mut samples = Vec::with_capacity(bytes.len() / 4);
    for chunk in bytes.chunks(64 * 1024) {
        check()?;
        hash.update(chunk);
    }
    for (i, word) in bytes.as_chunks::<4>().0.iter().enumerate() {
        if i % (RATE * 4) == 0 {
            check()?;
        }
        let value = f32::from_le_bytes(*word);
        if !value.is_finite() {
            return Err("Non-finite comparison PCM".into());
        }
        samples.push(value);
    }
    Ok((
        samples,
        hash.finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    ))
}

pub fn compare_files(path_a: &str, path_b: &str, check: Check<'_>) -> Result<Comparison, String> {
    let (a, hash_a) = decode(path_a, check)?;
    let (b, hash_b) = decode(path_b, check)?;
    let duration_a = a.len() as f64 / RATE as f64;
    let duration_b = b.len() as f64 / RATE as f64;
    // Byte identity proves sameness, never the absence of censorship.
    if hash_a == hash_b {
        return Ok(Comparison {
            version: VERSION,
            status: "identical_audio",
            source_a_sha256: hash_a,
            source_b_sha256: hash_b,
            duration_a,
            duration_b,
            alignment: Alignment {
                decision: "identical_audio",
                offset: Some(0.0),
                anchors: Vec::new(),
            },
            shared_start_a: Some(0.0),
            shared_start_b: Some(0.0),
            shared_duration: Some(duration_a),
            usable_bands: 0,
            candidates: Vec::new(),
            preferred_side: None,
            absolute_uncensored_status: "unknown",
        });
    }
    let alignment = audio_version_alignment::align(&a, &b, check)?;
    let mut result = Comparison {
        version: VERSION,
        status: "alignment_unreliable",
        source_a_sha256: hash_a,
        source_b_sha256: hash_b,
        duration_a,
        duration_b,
        alignment,
        shared_start_a: None,
        shared_start_b: None,
        shared_duration: None,
        usable_bands: 0,
        candidates: Vec::new(),
        preferred_side: None,
        absolute_uncensored_status: "unknown",
    };
    let Some(offset) = result.alignment.offset else {
        return Ok(result);
    };
    let bs = 0.0_f64.max(-offset);
    let be = duration_b.min(duration_a - offset);
    result.shared_start_a = Some(bs + offset);
    result.shared_start_b = Some(bs);
    result.shared_duration = Some(be - bs);
    let metrics = metrics(a, b, offset, check)?;
    result.usable_bands = metrics.usable;
    if metrics.usable < 12 {
        result.status = "insufficient_shared_bandwidth";
        return Ok(result);
    }
    result.candidates = candidates(&metrics, bs, offset);
    result.status = "model_verification_required";
    // Even no candidates does not certify an uncensored recording.
    Ok(result)
}

struct Metrics {
    usable: usize,
    cosine: Vec<f64>,
    relative: Vec<f64>,
    audible: Vec<f64>,
    a_drop: Vec<f64>,
    b_drop: Vec<f64>,
}
fn normalize(audio: &mut [f32]) {
    let rms = (audio.iter().map(|&x| (x as f64).powi(2)).sum::<f64>() / audio.len() as f64).sqrt();
    let gain = 0.1 / rms.max(1e-9);
    for value in audio {
        *value = (*value as f64 * gain) as f32;
    }
}
fn rms_db(samples: &[f32], frames: usize) -> Vec<f64> {
    let n = samples.len() as isize;
    let square = |i: isize| {
        let index = if i < 0 {
            -i - 1
        } else if i >= n {
            2 * n - i - 1
        } else {
            i
        };
        (samples[index as usize] as f64).powi(2)
    };
    let size = RATE as isize / 10;
    let left = size / 2;
    let mut sum: f64 = (-left..size - left).map(square).sum();
    let mut result = Vec::with_capacity(frames);
    let mut position = 0;
    for frame in 0..frames {
        while position < frame as isize * HOP as isize {
            position += 1;
            sum += square(position + size - left - 1) - square(position - left - 1);
        }
        result.push(10.0 * (sum / size as f64).max(1e-12).log10());
    }
    result
}
fn metrics(
    mut a: Vec<f32>,
    mut b: Vec<f32>,
    offset: f64,
    check: Check<'_>,
) -> Result<Metrics, String> {
    normalize(&mut a);
    normalize(&mut b);
    check()?;
    let bs = 0.0_f64.max(-offset);
    let be = (b.len() as f64 / RATE as f64).min(a.len() as f64 / RATE as f64 - offset);
    let aa = extract(&a, bs + offset, be - bs);
    let bb = extract(&b, bs, be - bs);
    drop(a);
    drop(b);
    let mut af = features(&aa, check)?;
    let mut bf = features(&bb, check)?;
    let n = af.len().min(bf.len());
    af.truncate(n);
    bf.truncate(n);
    let eq: Frame = std::array::from_fn(|j| {
        median(
            &af.iter()
                .zip(&bf)
                .map(|(a, b)| a[j] - b[j])
                .collect::<Vec<_>>(),
        )
    });
    let center = median(&eq);
    let ma: Frame = std::array::from_fn(|j| af.iter().map(|r| r[j].exp()).sum::<f64>() / n as f64);
    let mb: Frame = std::array::from_fn(|j| bf.iter().map(|r| r[j].exp()).sum::<f64>() / n as f64);
    let max_a = ma.iter().copied().fold(0.0, f64::max);
    let max_b = mb.iter().copied().fold(0.0, f64::max);
    let freq = frequencies();
    let usable: Vec<_> = (0..BANDS)
        .filter(|&j| {
            freq[j] < 2800.0
                && (eq[j] - center).abs() < 10.0_f64.ln() * 1.2
                && ma[j] > max_a * 1e-5
                && mb[j] > max_b * 1e-5
        })
        .collect();
    if usable.len() < 12 {
        return Ok(Metrics {
            usable: usable.len(),
            cosine: Vec::new(),
            relative: Vec::new(),
            audible: Vec::new(),
            a_drop: Vec::new(),
            b_drop: Vec::new(),
        });
    }
    let mut cosine = Vec::with_capacity(n);
    let mut a_drop = Vec::with_capacity(n);
    let mut b_drop = Vec::with_capacity(n);
    for (index, (a, b)) in af.iter().zip(&bf).enumerate() {
        if index % 128 == 0 {
            check()?;
        }
        let maxa = a.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let maxb = (0..BANDS)
            .map(|j| b[j] + eq[j])
            .fold(f64::NEG_INFINITY, f64::max);
        let mut dot = 0.0;
        let mut uu = 0.0;
        let mut vv = 0.0;
        let mut dropped_a = 0;
        let mut dropped_b = 0;
        for &j in &usable {
            let u = ((a[j] - maxa) * 0.25).exp();
            let v = ((b[j] + eq[j] - maxb) * 0.25).exp();
            dot += u * v;
            uu += u * u;
            vv += v * v;
            let drop = (a[j] - b[j] - eq[j]) * 10.0 / 10.0_f64.ln();
            dropped_a += usize::from(drop <= -18.0);
            dropped_b += usize::from(drop >= 18.0);
        }
        cosine.push((1.0 - dot / (uu * vv).sqrt().max(1e-12)).max(0.0));
        a_drop.push(dropped_a as f64 / usable.len() as f64);
        b_drop.push(dropped_b as f64 / usable.len() as f64);
    }
    let da = rms_db(&aa, n);
    let db = rms_db(&bb, n);
    let mut relative: Vec<_> = db.iter().zip(&da).map(|(b, a)| b - a).collect();
    let median = median(&relative);
    for value in &mut relative {
        *value -= median;
    }
    let audible = da.iter().zip(&db).map(|(a, b)| a.max(*b)).collect();
    Ok(Metrics {
        usable: usable.len(),
        cosine: smooth(&cosine, 30),
        relative,
        audible,
        a_drop,
        b_drop,
    })
}
fn groups(mask: impl Iterator<Item = bool>, minimum: usize) -> Vec<(usize, usize)> {
    let mut groups = Vec::new();
    let mut start = None;
    let mut length = 0;
    for (i, valid) in mask.enumerate() {
        length = i + 1;
        if valid {
            if start.is_none() {
                start = Some(i);
            }
        } else if let Some(left) = start.take()
            && i - left >= minimum
        {
            groups.push((left, i));
        }
    }
    if let Some(left) = start
        && length - left >= minimum
    {
        groups.push((left, length));
    }
    groups
}
fn candidates(m: &Metrics, bs: f64, offset: f64) -> Vec<Candidate> {
    let n = m.cosine.len();
    if n == 0 {
        return Vec::new();
    }
    let time = |i: usize| i as f64 * 0.01 + 0.032 + bs;
    let valid = |i: usize| {
        time(i) >= time(0) + 1.5 && time(i) <= time(n - 1) - 1.5 && m.audible[i] >= -60.0
    };
    let spectral = groups((0..n).map(|i| valid(i) && m.cosine[i] >= 0.03), 15);
    let mut out = Vec::new();
    for (first, last) in spectral {
        out.push(Candidate {
            start_a: time(first) + offset,
            end_a: time(last - 1) + 0.01 + offset,
            start_b: time(first),
            end_b: time(last - 1) + 0.01,
            kind: "spectral_edit_candidate",
            peak_score: m.cosine[first..last].iter().copied().fold(0.0, f64::max),
        });
    }
    let gaps = groups(
        (0..n).map(|i| {
            valid(i) && m.relative[i].abs() >= 24.0 && (m.a_drop[i] >= 0.7 || m.b_drop[i] >= 0.7)
        }),
        12,
    );
    for (first, last) in gaps {
        let begin = first.saturating_sub(20).max(6);
        let end = (last + 20).min(n.saturating_sub(6));
        let sharpness = (begin..end)
            .map(|i| (m.relative[i + 6] - m.relative[i - 6]).abs())
            .fold(0.0, f64::max);
        if sharpness < 12.0 {
            continue;
        }
        out.push(Candidate {
            start_a: time(first) + offset,
            end_a: time(last - 1) + 0.01 + offset,
            start_b: time(first),
            end_b: time(last - 1) + 0.01,
            kind: "severe_local_drop_candidate",
            peak_score: sharpness,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_version_spectral::fixture_audio;
    #[test]
    fn alignment_and_candidates_match_frozen_python_for_gain_and_mute() {
        let golden: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/audio_version_golden.json"))
                .unwrap();
        let a = fixture_audio(36);
        for case in golden["cases"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let mut b = vec![0.0; 1217];
            b.extend(a.iter().enumerate().map(|(i, &x)| {
                if name == "mute_delay" && (18_500 * 16..19_100 * 16).contains(&i) {
                    0.0
                } else {
                    x * 0.6
                }
            }));
            let aligned = audio_version_alignment::align(&a, &b, &|| Ok(())).unwrap();
            assert_eq!(aligned.decision, "aligned", "{name}: {aligned:?}");
            let offset = aligned.offset.unwrap();
            let wanted = case["offset"].as_f64().unwrap();
            assert!(
                (offset - wanted).abs() <= 1.0 / RATE as f64,
                "{name}: {offset} vs {wanted}"
            );
            let metrics = metrics(a.clone(), b, offset, &|| Ok(())).unwrap();
            assert_eq!(
                metrics.usable,
                case["usable_bands"].as_u64().unwrap() as usize
            );
            let found = candidates(&metrics, 0.0_f64.max(-offset), offset);
            let want = case["events"].as_array().unwrap();
            assert_eq!(found.len(), want.len(), "{name}: {found:?} vs {want:?}");
            for (event, want) in found.iter().zip(want) {
                assert!((event.start_b - want["start_B"].as_f64().unwrap()).abs() < 0.011);
                assert!((event.end_b - want["end_B"].as_f64().unwrap()).abs() < 0.011);
                assert_eq!(event.kind, want["kind"].as_str().unwrap());
            }
        }
    }
    fn file(samples: &[f32]) -> tempfile::NamedTempFile {
        use std::io::Write;
        let mut file = tempfile::NamedTempFile::new().unwrap();
        for value in samples {
            file.write_all(&value.to_le_bytes()).unwrap();
        }
        file
    }
    #[test]
    fn identical_audio_is_unknown_not_uncensored() {
        let f = file(&fixture_audio(13));
        let r = compare_files(
            f.path().to_str().unwrap(),
            f.path().to_str().unwrap(),
            &|| Ok(()),
        )
        .unwrap();
        assert_eq!(r.status, "identical_audio");
        assert!(r.preferred_side.is_none());
        assert_eq!(r.absolute_uncensored_status, "unknown");
        assert_eq!(r.source_a_sha256, r.source_b_sha256);
    }
    #[test]
    fn rejects_truncated_nonfinite_oversized_and_short_pcm() {
        use std::io::Write;
        let mut f = tempfile::NamedTempFile::new().unwrap();
        f.write_all(&[1, 2, 3]).unwrap();
        assert!(decode(f.path().to_str().unwrap(), &|| Ok(())).is_err());
        f.as_file().set_len((MAX_BYTES + 4) as u64).unwrap();
        assert!(decode(f.path().to_str().unwrap(), &|| Ok(())).is_err());
        let f = file(&[0.0; 32]);
        assert!(decode(f.path().to_str().unwrap(), &|| Ok(())).is_err());
        let mut values = vec![0.0; RATE * 13];
        values[100] = f32::NAN;
        let f = file(&values);
        assert!(decode(f.path().to_str().unwrap(), &|| Ok(())).is_err());
    }
    #[test]
    fn unrelated_recordings_do_not_acquire_an_alignment() {
        let a = fixture_audio(25);
        let b: Vec<_> = a.iter().rev().copied().collect();
        let result = audio_version_alignment::align(&a, &b, &|| Ok(())).unwrap();
        assert!(result.offset.is_none(), "{result:?}");
    }
}
