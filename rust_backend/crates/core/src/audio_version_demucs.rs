//! Exact HTDemucs FFT boundary. All tensors are planar little endian f32.
use crate::audio_version_spectral::Check;
use std::path::Path;
pub const SEGMENT: usize = 343980;
pub const FRAMES: usize = 336;
pub const FFT: usize = 4096;
pub const HOP: usize = 1024;
pub const SHA: &str = "273be7e599749c71ef29b6f34c20721937c336aa85b3e1f2fde5b57a987f07ba";
fn fft(a: &mut [(f64, f64)], inverse: bool) {
    let n = a.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            a.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let angle = if inverse { 2.0 } else { -2.0 } * std::f64::consts::PI / len as f64;
        let w = (angle.cos(), angle.sin());
        for base in (0..n).step_by(len) {
            let mut u = (1.0, 0.0);
            for k in 0..len / 2 {
                let b = a[base + k + len / 2];
                let v = (b.0 * u.0 - b.1 * u.1, b.0 * u.1 + b.1 * u.0);
                let t = a[base + k];
                a[base + k] = (t.0 + v.0, t.1 + v.1);
                a[base + k + len / 2] = (t.0 - v.0, t.1 - v.1);
                u = (u.0 * w.0 - u.1 * w.1, u.0 * w.1 + u.1 * w.0);
            }
        }
        len *= 2;
    }
}
fn window(i: usize) -> f64 {
    (0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / FFT as f64).cos()) as f32 as f64
}
fn reflect(mut i: isize, n: usize) -> usize {
    while i < 0 || i >= n as isize {
        if i < 0 {
            i = -i;
        }
        if i >= n as isize {
            i = 2 * n as isize - 2 - i;
        }
    }
    i as usize
}
pub fn spectrum(wave: &[f32], check: Check<'_>) -> Result<Vec<f32>, String> {
    if wave.len() != 2 * SEGMENT {
        return Err("Invalid Demucs waveform shape".into());
    }
    let mut out = vec![0.; 4 * 2048 * FRAMES];
    let hann: Vec<_> = (0..FFT).map(window).collect();
    let pad = 1536;
    let outer = SEGMENT + 2 * pad + FRAMES * HOP - SEGMENT;
    for c in 0..2 {
        for frame in 0..FRAMES {
            check()?;
            let mut x = vec![(0., 0.); FFT];
            for (i, v) in x.iter_mut().enumerate() {
                let first = reflect(((frame + 2) * HOP + i) as isize - 2048, outer);
                let original = reflect(first as isize - pad as isize, SEGMENT);
                v.0 = (wave[c * SEGMENT + original] * hann[i] as f32) as f64;
            }
            fft(&mut x, false);
            for f in 0..2048 {
                out[((c * 2) * 2048 + f) * FRAMES + frame] = (x[f].0 / 64.) as f32;
                out[((c * 2 + 1) * 2048 + f) * FRAMES + frame] = (x[f].1 / 64.) as f32;
            }
        }
    }
    Ok(out)
}
pub fn reconstruct(freq: &[f32], time: &[f32], check: Check<'_>) -> Result<Vec<f32>, String> {
    if freq.len() != 4 * 4 * 2048 * FRAMES || time.len() != 4 * 2 * SEGMENT {
        return Err("Invalid Demucs output shape".into());
    }
    let hann: Vec<_> = (0..FFT).map(window).collect();
    let count = FRAMES + 4;
    let size = (count - 1) * HOP + FFT;
    let mut denom = vec![0f64; size];
    for f in 0..count {
        for i in 0..FFT {
            denom[f * HOP + i] += hann[i].powi(2);
        }
    }
    let mut out = time.to_vec();
    for s in 0..4 {
        for c in 0..2 {
            let mut audio = vec![0f64; size];
            for frame in 2..FRAMES + 2 {
                check()?;
                let mut x = vec![(0., 0.); FFT];
                for f in 0..2048 {
                    let at = (((s * 4 + c * 2) * 2048 + f) * FRAMES) + frame - 2;
                    x[f] = (freq[at] as f64, freq[at + 2048 * FRAMES] as f64);
                    if f > 0 {
                        x[FFT - f] = (x[f].0, -x[f].1);
                    }
                }
                fft(&mut x, true);
                for i in 0..FFT {
                    audio[frame * HOP + i] += x[i].0 / 64. * hann[i];
                }
            }
            for i in 0..SEGMENT {
                let at = i + 2048 + 1536;
                out[(s * 2 + c) * SEGMENT + i] += (audio[at] / denom[at].max(1e-12)) as f32;
            }
        }
    }
    Ok(out)
}
pub fn read(path: &str, max: usize, check: Check<'_>) -> Result<Vec<f32>, String> {
    let bytes = crate::native_audio_analysis::read_bounded(path, max * 4, check)?;
    if bytes.len() % 4 != 0 {
        return Err("Invalid float tensor".into());
    }
    bytes
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| {
            let v = f32::from_le_bytes(*b);
            if v.is_finite() {
                Ok(v)
            } else {
                Err("Non finite Demucs tensor".into())
            }
        })
        .collect()
}
pub fn write(path: &str, data: &[f32], check: Check<'_>) -> Result<(), String> {
    use std::io::Write;
    let mut file =
        tempfile::NamedTempFile::new_in(Path::new(path).parent().ok_or("Missing output parent")?)
            .map_err(|e| e.to_string())?;
    for chunk in data.chunks(16384) {
        check()?;
        let bytes: Vec<_> = chunk.iter().flat_map(|v| v.to_le_bytes()).collect();
        file.write_all(&bytes).map_err(|e| e.to_string())?;
    }
    check()?;
    file.persist_noclobber(path).map_err(|e| e.to_string())?;
    Ok(())
}
/// Interleaved stereo context, normalized once across the entire context. TensorChunk.padded uses available context before zero padding.
pub fn prepare(
    input: &str,
    offset: usize,
    wave_path: &str,
    spec_path: &str,
    check: Check<'_>,
) -> Result<serde_json::Value, String> {
    let pcm = read(input, 44100 * 12 * 2, check)?;
    if pcm.len() < 4 || pcm.len() % 2 != 0 {
        return Err("Invalid stereo context".into());
    }
    let n = pcm.len() / 2;
    if offset >= n {
        return Err("Invalid chunk offset".into());
    }
    let mono: Vec<_> = pcm
        .as_chunks::<2>()
        .0
        .iter()
        .map(|x| (x[0] as f64 + x[1] as f64) / 2.)
        .collect();
    let mean = mono.iter().sum::<f64>() / n as f64;
    let std = (mono.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1) as f64)
        .sqrt()
        .max(1e-6);
    let length = (n - offset).min(SEGMENT);
    let delta = (SEGMENT - length) / 2;
    let begin = offset.saturating_sub(delta);
    let end = (offset + SEGMENT - delta).min(n);
    let left = delta.saturating_sub(offset);
    let mut wave = vec![0.; 2 * SEGMENT];
    for c in 0..2 {
        for i in begin..end {
            wave[c * SEGMENT + left + i - begin] = ((pcm[i * 2 + c] as f64 - mean) / std) as f32;
        }
    }
    let spec = spectrum(&wave, check)?;
    write(wave_path, &wave, check)?;
    write(spec_path, &spec, check)?;
    Ok(
        serde_json::json!({"samples":n,"offset":offset,"length":length,"trim_left":delta,"mean":mean,"std":std,"segment":SEGMENT,"stride":257985,"model_sha256":SHA}),
    )
}
pub fn finish(freq: &str, time: &str, output: &str, check: Check<'_>) -> Result<(), String> {
    let f = read(freq, 4 * 4 * 2048 * FRAMES, check)?;
    let t = read(time, 4 * 2 * SEGMENT, check)?;
    write(output, &reconstruct(&f, &t, check)?, check)
}
/// Weighted overlap/add exactly as apply_model(overlap=0.25, transition_power=1).
pub fn merge(
    chunks: &[String],
    samples: usize,
    mean: f64,
    std: f64,
    output: &str,
    check: Check<'_>,
) -> Result<(), String> {
    if samples == 0 || samples > 44100 * 12 || !mean.is_finite() || !std.is_finite() || std < 1e-6 {
        return Err("Invalid Demucs merge".into());
    }
    let stride = 257985;
    if chunks.len() != samples.div_ceil(stride) {
        return Err("Missing Demucs chunk".into());
    }
    let mut out = vec![0f32; 8 * samples];
    let mut weights = vec![0f64; samples];
    for (j, path) in chunks.iter().enumerate() {
        let data = read(path, 8 * SEGMENT, check)?;
        if data.len() != 8 * SEGMENT {
            return Err("Invalid separated chunk".into());
        }
        let offset = j * stride;
        let len = (samples - offset).min(SEGMENT);
        let trim = (SEGMENT - len) / 2;
        for i in 0..len {
            let weight = ((i + 1).min(SEGMENT - i) as f64) / (SEGMENT / 2) as f64;
            weights[offset + i] += weight;
            for c in 0..8 {
                out[c * samples + offset + i] +=
                    (data[c * SEGMENT + trim + i] as f64 * weight) as f32;
            }
        }
    }
    for c in 0..8 {
        for i in 0..samples {
            out[c * samples + i] = (out[c * samples + i] as f64 / weights[i] * std + mean) as f32;
        }
    }
    write(output, &out, check)
}

fn quantile(v: &[f64], p: f64) -> f64 {
    let mut a = v.to_vec();
    a.sort_by(f64::total_cmp);
    let pos = (a.len() - 1) as f64 * p;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    a[lo] + (a[hi] - a[lo]) * (pos - lo as f64)
}
fn med(v: &[f64]) -> Option<f64> {
    (!v.is_empty()).then(|| quantile(v, 0.5))
}
fn mono_stems(stems: &[f32], n: usize, source: usize) -> Vec<f64> {
    (0..n)
        .map(|i| (stems[(source * 2) * n + i] as f64 + stems[(source * 2 + 1) * n + i] as f64) / 2.)
        .collect()
}
fn frame_db(x: &[f64]) -> Vec<f64> {
    let window = 2205usize;
    let half = window / 2;
    let mut prefix = Vec::with_capacity(x.len() + window + 1);
    prefix.push(0.);
    for i in 0..x.len() + window {
        let mut j = i as isize - half as isize;
        while j < 0 || j >= x.len() as isize {
            if j < 0 {
                j = -j - 1;
            }
            if j >= x.len() as isize {
                j = 2 * x.len() as isize - j - 1;
            }
        }
        let p = *prefix.last().unwrap() + x[j as usize].powi(2);
        prefix.push(p);
    }
    (0..x.len())
        .step_by(441)
        .map(|i| {
            10. * ((prefix[i + window] - prefix[i]) / window as f64)
                .max(1e-12)
                .log10()
        })
        .collect()
}
fn rms_db(x: &[f64], left: usize, right: usize) -> f64 {
    20. * (x[left..right].iter().map(|v| v * v).sum::<f64>() / (right - left) as f64)
        .sqrt()
        .max(1e-12)
        .log10()
}
/// Relative vocal completeness, only over confirmed shared-interval events. Absolute status stays unknown.
// File boundary mirrors the typed native job contract.
#[allow(clippy::too_many_arguments)]
pub fn direction(
    a_stems: &str,
    b_stems: &str,
    a_mix: &str,
    b_mix: &str,
    samples: usize,
    start_b: f64,
    events: &[crate::audio_version_content::Event],
    all: &[crate::audio_version_content::Event],
    check: Check<'_>,
) -> Result<serde_json::Value, String> {
    if !(2..=44100 * 12).contains(&samples)
        || !start_b.is_finite()
        || start_b < 0.
        || events.len() > 10000
        || all.len() > 10000
    {
        return Err("Invalid direction context".into());
    }
    for e in events.iter().chain(all) {
        if !e.start_b.is_finite() || !e.end_b.is_finite() || e.start_b < 0. || e.end_b <= e.start_b
        {
            return Err("Invalid direction event".into());
        }
    }
    if events
        .iter()
        .any(|e| e.start_b < start_b || e.end_b > start_b + samples as f64 / 44100. + 0.01)
    {
        return Err("Selected direction event outside context".into());
    }
    if events.iter().any(|e| {
        !all.iter()
            .any(|a| a.start_b <= e.start_b && a.end_b >= e.end_b)
    }) {
        return Err("Direction event missing baseline exclusion".into());
    }
    let a = read(a_stems, 8 * samples, check)?;
    let b = read(b_stems, 8 * samples, check)?;
    let am = read(a_mix, 2 * samples, check)?;
    let bm = read(b_mix, 2 * samples, check)?;
    if a.len() != 8 * samples
        || b.len() != 8 * samples
        || am.len() != 2 * samples
        || bm.len() != 2 * samples
    {
        return Err("Direction tensor size mismatch".into());
    }
    let av = mono_stems(&a, samples, 3);
    let bv = mono_stems(&b, samples, 3);
    let music = |stems: &[f32]| {
        let mut m = vec![0.; samples];
        for s in 0..3 {
            for (o, v) in m.iter_mut().zip(mono_stems(stems, samples, s)) {
                *o += v;
            }
        }
        m
    };
    let au = music(&a);
    let bu = music(&b);
    let mono = |x: &[f32]| {
        x.as_chunks::<2>()
            .0
            .iter()
            .map(|v| (v[0] as f64 + v[1] as f64) / 2.)
            .collect::<Vec<_>>()
    };
    let da = frame_db(&av);
    let db = frame_db(&bv);
    let ma = frame_db(&mono(&am));
    let mb = frame_db(&mono(&bm));
    let qa = quantile(&da, 0.9);
    let qb = quantile(&db, 0.9);
    let qma = quantile(&ma, 0.9);
    let qmb = quantile(&mb, 0.9);
    let outside = |i: usize| {
        let t = start_b + i as f64 * 0.01;
        all.iter()
            .all(|e| t < e.start_b - 0.15 || t > e.end_b + 0.15)
    };
    let baseline_values: Vec<_> = (0..da.len())
        .filter(|&i| outside(i) && da[i] >= qa - 15. && db[i] >= qb - 15.)
        .map(|i| db[i] - da[i])
        .collect();
    let baseline = (baseline_values.len() >= 100).then(|| med(&baseline_values).unwrap());
    let mix_values: Vec<_> = (0..ma.len())
        .filter(|&i| outside(i) && ma[i] >= qma - 20. && mb[i] >= qmb - 20.)
        .map(|i| mb[i] - ma[i])
        .collect();
    let mix_base = (mix_values.len() >= 100).then(|| med(&mix_values).unwrap());
    let mut rows = Vec::new();
    let mut vote_a = false;
    let mut vote_b = false;
    for e in events {
        check()?;
        let indices: Vec<_> = (0..da.len())
            .filter(|&i| {
                let t = start_b + i as f64 * 0.01;
                t >= e.start_b && t <= e.end_b
            })
            .collect();
        let local = baseline.and_then(|base| {
            med(&indices.iter().map(|&i| db[i] - da[i]).collect::<Vec<_>>()).map(|v| v - base)
        });
        let whole = mix_base.and_then(|base| {
            med(&indices.iter().map(|&i| mb[i] - ma[i]).collect::<Vec<_>>()).map(|v| v - base)
        });
        let left = (((e.start_b - start_b) * 44100.).round() as usize).min(samples);
        let right = (((e.end_b - start_b) * 44100.).round() as usize).min(samples);
        let balance = (right > left).then(|| {
            (rms_db(&bv, left, right) - rms_db(&bu, left, right))
                - (rms_db(&av, left, right) - rms_db(&au, left, right))
        });
        let voice = if whole.is_some_and(|v| v < 0.) {
            med(&indices.iter().map(|&i| da[i]).collect::<Vec<_>>()).is_some_and(|v| v >= qa - 20.)
        } else {
            med(&indices.iter().map(|&i| db[i]).collect::<Vec<_>>()).is_some_and(|v| v >= qb - 20.)
        };
        let suppressed = if whole.is_some_and(|v| v <= -24.) && voice {
            "B_suppressed"
        } else if whole.is_some_and(|v| v >= 24.) && voice {
            "A_suppressed"
        } else if local.is_some_and(|v| v <= -3.) && balance.is_some_and(|v| v <= -3.) {
            "B_suppressed"
        } else if local.is_some_and(|v| v >= 3.) && balance.is_some_and(|v| v >= 3.) {
            "A_suppressed"
        } else {
            "undetermined"
        };
        vote_a |= suppressed == "B_suppressed";
        vote_b |= suppressed == "A_suppressed";
        rows.push(serde_json::json!({"start_b":e.start_b,"end_b":e.end_b,"direction":suppressed,"local_vocal_gain_b_minus_a_db":local,"relative_vocal_balance_b_minus_a_db":balance,"whole_mix_b_minus_a_db":whole,"baseline_seconds":baseline_values.len() as f64*0.01}));
    }
    Ok(
        serde_json::json!({"model_sha256":SHA,"preferred_side":if vote_a&&!vote_b {Some("A")}else if vote_b&&!vote_a {Some("B")}else{None},"assessment":if vote_a&&vote_b {"mixed_local_changes"}else if vote_a||vote_b {"relative_vocal_loss_supported"}else{"undetermined"},"events":rows,"absolute_uncensored_status":"unknown","scope":"confirmed_shared_interval_events"}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn boundary_matches_independent_numpy_golden() {
        let wave: Vec<_> = (0..2 * SEGMENT)
            .map(|j| {
                let i = j % SEGMENT;
                if j < SEGMENT {
                    let u = ((i as u64 + 1) * 1664525 + 1013904223) % 4294967296;
                    (0.2 * (i as f64 * 0.013).sin() + 0.01 * (u as f64 / 2147483648. - 1.)) as f32
                } else {
                    (0.15 * (i as f64 * 0.027).cos()) as f32
                }
            })
            .collect();
        let z = spectrum(&wave, &|| Ok(())).unwrap();
        let golden: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/audio_version_demucs_golden.json"
        ))
        .unwrap();
        for p in golden["spectrum"].as_array().unwrap() {
            let c = p["channel"].as_u64().unwrap() as usize;
            let f = p["frequency"].as_u64().unwrap() as usize;
            let t = p["frame"].as_u64().unwrap() as usize;
            let actual = z[(c * 2048 + f) * FRAMES + t];
            let want = p["value"].as_f64().unwrap();
            assert!(
                (actual as f64 - want).abs() < 2e-6,
                "spec {c}/{f}/{t}: {actual} vs {want}"
            );
        }
        let mut f = vec![0.; 16 * 2048 * FRAMES];
        f[..z.len()].copy_from_slice(&z);
        let actual = reconstruct(&f, &vec![0.; 8 * SEGMENT], &|| Ok(())).unwrap();
        for p in golden["inverse"].as_array().unwrap() {
            let c = p["channel"].as_u64().unwrap() as usize;
            let i = p["sample"].as_u64().unwrap() as usize;
            assert!(
                (actual[c * SEGMENT + i] as f64 - p["value"].as_f64().unwrap()).abs() < 2e-6,
                "inverse {c}/{i}"
            );
        }
    }
    #[test]
    fn direction_matches_numpy_with_role_swaps_and_opposing_edits() {
        let golden: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/audio_version_demucs_golden.json"
        ))
        .unwrap();
        let n = 44100 * 12;
        let tmp = tempfile::tempdir().unwrap();
        for kind in ["vocal", "whole", "mixed"] {
            let mut a = vec![0f32; 8 * n];
            let mut b = a.clone();
            let mut am = vec![0f32; 2 * n];
            let mut bm = am.clone();
            for i in 0..n {
                let t = i as f64 / 44100.;
                let v = (0.16 * (2. * std::f64::consts::PI * 223. * t).sin()) as f32;
                let m = (0.12 * (2. * std::f64::consts::PI * 137. * t).sin()) as f32;
                let mut av = v;
                let mut bv = v * 0.7;
                let mut bu = m * 0.7;
                if (176400..194040).contains(&i) {
                    if kind == "whole" {
                        bv = 0.;
                        bu = 0.;
                    } else {
                        bv *= 0.1;
                    }
                }
                if kind == "mixed" && (352800..370440).contains(&i) {
                    av *= 0.1;
                }
                for c in 0..2 {
                    a[(6 + c) * n + i] = av;
                    b[(6 + c) * n + i] = bv;
                    a[(4 + c) * n + i] = m;
                    b[(4 + c) * n + i] = bu;
                    am[2 * i + c] = av + m;
                    bm[2 * i + c] = bv + bu;
                }
            }
            let paths: Vec<_> = ["a", "b", "am", "bm"]
                .iter()
                .map(|x| tmp.path().join(format!("{kind}{x}")))
                .collect();
            for (p, data) in paths.iter().zip([&a, &b, &am, &bm]) {
                write(p.to_str().unwrap(), data, &|| Ok(())).unwrap();
            }
            let p: Vec<_> = paths.iter().map(|x| x.to_str().unwrap()).collect();
            let mut events = vec![crate::audio_version_content::Event {
                start_b: 4.,
                end_b: 4.4,
            }];
            if kind == "mixed" {
                events.push(crate::audio_version_content::Event {
                    start_b: 8.,
                    end_b: 8.4,
                });
            }
            let result =
                direction(p[0], p[1], p[2], p[3], n, 0., &events, &events, &|| Ok(())).unwrap();
            assert_eq!(
                result["preferred_side"],
                if kind == "mixed" {
                    serde_json::Value::Null
                } else {
                    serde_json::json!("A")
                }
            );
            assert_eq!(result["absolute_uncensored_status"], "unknown");
            for (actual, want) in result["events"]
                .as_array()
                .unwrap()
                .iter()
                .zip(golden["direction"][kind].as_array().unwrap())
            {
                for (field, gfield) in [
                    ("local_vocal_gain_b_minus_a_db", "local"),
                    ("relative_vocal_balance_b_minus_a_db", "balance"),
                    ("whole_mix_b_minus_a_db", "whole"),
                ] {
                    assert!(
                        (actual[field].as_f64().unwrap() - want[gfield].as_f64().unwrap()).abs()
                            < 0.001,
                        "{kind} {field}: {} vs {}",
                        actual[field],
                        want[gfield]
                    );
                }
            }
            let identical =
                direction(p[0], p[0], p[2], p[2], n, 0., &events, &events, &|| Ok(())).unwrap();
            assert!(identical["preferred_side"].is_null());
            let full = vec![crate::audio_version_content::Event {
                start_b: 0.,
                end_b: 12.,
            }];
            let no_baseline =
                direction(p[0], p[1], p[2], p[3], n, 0., &full, &full, &|| Ok(())).unwrap();
            assert!(no_baseline["preferred_side"].is_null());
            let swapped =
                direction(p[1], p[0], p[3], p[2], n, 0., &events, &events, &|| Ok(())).unwrap();
            assert_eq!(
                swapped["preferred_side"],
                if kind == "mixed" {
                    serde_json::Value::Null
                } else {
                    serde_json::json!("B")
                }
            );
        }
    }
}
