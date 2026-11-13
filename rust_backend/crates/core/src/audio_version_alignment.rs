//! Multi-hypothesis alignment port. A repeated hook is never enough to align a pair.
use crate::audio_version_spectral::*;
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
pub struct Anchor {
    pub time_b: f64,
    pub spectral_correlation: f64,
    pub lag_adjustment: f64,
    pub peak_margin: f64,
}
#[derive(Debug, Serialize)]
pub struct Alignment {
    pub decision: &'static str,
    pub offset: Option<f64>,
    pub anchors: Vec<Anchor>,
}

fn argmax(values: &[f64]) -> usize {
    values
        .iter()
        .enumerate()
        .max_by(|(ia, a), (ib, b)| a.total_cmp(b).then_with(|| ib.cmp(ia)))
        .map_or(0, |(i, _)| i)
}
fn band_count(low: bool) -> usize {
    if low {
        frequencies().iter().filter(|&&f| f < 2800.0).count()
    } else {
        BANDS
    }
}
fn centered(frames: &[Frame], bands: usize) -> Vec<Frame> {
    frames
        .iter()
        .step_by(5)
        .map(|row| {
            let mean = row[..bands].iter().sum::<f64>() / bands as f64;
            std::array::from_fn(|j| if j < bands { row[j] - mean } else { 0.0 })
        })
        .collect()
}
fn scale_pair(a: &mut [Frame], b: &mut [Frame], bands: usize) {
    for j in 0..bands {
        let values: Vec<_> = a.iter().map(|r| r[j]).collect();
        let center = median(&values);
        let mean = values.iter().sum::<f64>() / values.len() as f64;
        let scale = (values.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / values.len() as f64)
            .sqrt()
            .max(0.5);
        for row in a.iter_mut().chain(b.iter_mut()) {
            row[j] = ((row[j] - center) / scale).clamp(-4.0, 4.0);
        }
    }
    for row in a.iter_mut().chain(b.iter_mut()) {
        let norm = row[..bands]
            .iter()
            .map(|x| x * x)
            .sum::<f64>()
            .sqrt()
            .max(1e-8);
        for value in &mut row[..bands] {
            *value /= norm;
        }
    }
}
fn frame_correlate(
    a: &[Frame],
    b: &[Frame],
    bands: usize,
    check: Check<'_>,
) -> Result<Vec<f64>, String> {
    if a.len() < b.len() || b.is_empty() {
        return Ok(Vec::new());
    }
    let mut result = vec![0.0; a.len() - b.len() + 1];
    for j in 0..bands {
        check()?;
        let x: Vec<_> = a.iter().map(|r| r[j]).collect();
        let y: Vec<_> = b.iter().map(|r| r[j]).collect();
        for (value, addition) in result.iter_mut().zip(correlate(&x, &y)) {
            *value += addition;
        }
    }
    Ok(result)
}
fn local_peaks(corr: &[f64]) -> Vec<usize> {
    let mut peaks = Vec::new();
    let mut i = 1;
    while i + 1 < corr.len() {
        if corr[i] > corr[i - 1] {
            let mut end = i;
            while end + 1 < corr.len() && corr[end + 1] == corr[i] {
                end += 1;
            }
            if end + 1 < corr.len() && corr[end] > corr[end + 1] {
                peaks.push((i + end) / 2);
            }
            i = end;
        }
        i += 1;
    }
    peaks.sort_by(|&a, &b| corr[b].total_cmp(&corr[a]));
    let mut kept = Vec::new();
    for peak in peaks {
        if kept.iter().all(|&p: &usize| p.abs_diff(peak) >= 40) {
            kept.push(peak);
        }
        if kept.len() == 3 {
            break;
        }
    }
    kept
}
fn hypotheses(a: &[Frame], b: &[Frame], check: Check<'_>) -> Result<Vec<f64>, String> {
    let count = band_count(true);
    let mut a = centered(a, count);
    let mut b = centered(b, count);
    if b.len() < 240 || a.len() < 240 {
        return Ok(Vec::new());
    }
    scale_pair(&mut a, &mut b, count);
    let mut rows = Vec::new();
    for share in [0.15, 0.5, 0.85] {
        let start = ((b.len() - 240) as f64 * share) as usize;
        let corr = frame_correlate(&a, &b[start..start + 240], count, check)?;
        for i in local_peaks(&corr) {
            rows.push(((i as f64 - start as f64) * 0.05, corr[i] / 240.0));
        }
    }
    rows.sort_by(|a, b| b.1.total_cmp(&a.1));
    Ok(rows.into_iter().map(|r| r.0).collect())
}
fn original_offset(
    a: &[f32],
    b: &[f32],
    fa: &[Frame],
    fb: &[Frame],
    check: Check<'_>,
) -> Result<f64, String> {
    let mut af = centered(fa, BANDS);
    let mut bf = centered(fb, BANDS);
    scale_pair(&mut af, &mut bf, BANDS);
    let start = bf.len().saturating_sub(480) / 2;
    let query = &bf[start..(start + 480).min(bf.len())];
    let corr = frame_correlate(&af, query, BANDS, check)?;
    if corr.is_empty() {
        return Ok(0.0);
    }
    let coarse = (argmax(&corr) as f64 - start as f64) * 0.05;
    let dur = b.len() as f64 / RATE as f64;
    let tb = (dur / 2.0 - 3.0).max(2.0).min((dur - 6.0).max(0.0));
    let length = 6.0_f64.min(dur - tb);
    let left = ((coarse + tb - 0.4) * RATE as f64).max(0.0) as usize;
    let right = (((coarse + tb + length + 0.4) * RATE as f64) as usize).min(a.len());
    if right <= left {
        return Ok(coarse);
    }
    let qstart = (tb * RATE as f64) as usize;
    let qend = ((tb + length) * RATE as f64) as usize;
    let aw = bandpass(&a[left..right]);
    let bw = bandpass(&b[qstart..qend.min(b.len())]);
    if aw.len() < bw.len() || bw.len() <= RATE {
        return Ok(coarse);
    }
    check()?;
    let fine = normalized_correlation(&aw, &bw);
    Ok((left + argmax(&fine)) as f64 / RATE as f64 - tb)
}
fn standardize(rows: &mut [Frame], bands: usize) {
    for j in 0..bands {
        let mean = rows.iter().map(|r| r[j]).sum::<f64>() / rows.len() as f64;
        let scale = (rows.iter().map(|r| (r[j] - mean).powi(2)).sum::<f64>() / rows.len() as f64)
            .sqrt()
            .max(0.5);
        for row in rows.iter_mut() {
            row[j] = (row[j] - mean) / scale;
        }
    }
}
fn anchors(a: &[f32], b: &[f32], offset: f64, check: Check<'_>) -> Result<Vec<Anchor>, String> {
    let bs = 2.0_f64.max(-offset + 2.0);
    let be = (b.len() as f64 / RATE as f64 - 8.0).min(a.len() as f64 / RATE as f64 - offset - 8.0);
    if be <= bs {
        return Ok(Vec::new());
    }
    let bands = band_count(true);
    let mut rows = Vec::new();
    for index in 0..9 {
        check()?;
        let t = bs + (be - bs) * index as f64 / 8.0;
        let mut af: Vec<_> = features(&extract(a, t + offset - 2.0, 10.0), check)?
            .into_iter()
            .step_by(2)
            .collect();
        let mut bf: Vec<_> = features(&extract(b, t, 6.0), check)?
            .into_iter()
            .step_by(2)
            .collect();
        standardize(&mut af, bands);
        standardize(&mut bf, bands);
        let mut corr = frame_correlate(&af, &bf, bands, check)?;
        let benergy = bf
            .iter()
            .flat_map(|r| &r[..bands])
            .map(|x| x * x)
            .sum::<f64>();
        let energy: Vec<_> = af
            .iter()
            .map(|r| r[..bands].iter().map(|x| x * x).sum::<f64>())
            .collect();
        let mut sum = energy[..bf.len()].iter().sum::<f64>();
        for (i, c) in corr.iter_mut().enumerate() {
            if i > 0 {
                sum += energy[i + bf.len() - 1] - energy[i - 1];
            }
            *c /= (sum * benergy).max(1e-12).sqrt();
        }
        let peak = argmax(&corr);
        let lag = peak as f64 * 0.02 - 2.0;
        let alternative = corr
            .iter()
            .enumerate()
            .filter(|(i, _)| ((*i as f64 * 0.02 - 2.0) - lag).abs() > 0.3)
            .map(|(_, x)| *x)
            .fold(f64::NEG_INFINITY, f64::max);
        rows.push(Anchor {
            time_b: t,
            spectral_correlation: corr[peak],
            lag_adjustment: lag,
            peak_margin: corr[peak] - alternative,
        });
    }
    Ok(rows)
}
fn good(a: &Anchor) -> bool {
    a.spectral_correlation >= 0.7 && a.peak_margin >= 0.12
}
fn gate(rows: &[Anchor]) -> bool {
    let goods: Vec<_> = rows.iter().filter(|a| good(a)).collect();
    if goods.len() < 6 {
        return false;
    }
    let center = median(&goods.iter().map(|a| a.lag_adjustment).collect::<Vec<_>>());
    let consistent: Vec<_> = goods
        .iter()
        .filter(|a| {
            (a.lag_adjustment - center).abs() <= 0.02000000001
                && a.lag_adjustment.abs() <= 0.02000000001
        })
        .collect();
    if consistent.len() < 6 {
        return false;
    }
    let span = consistent.last().unwrap().time_b - consistent[0].time_b;
    span >= 0.6 * (rows.last().unwrap().time_b - rows[0].time_b)
}
fn refine(a: &[f32], b: &[f32], offset: f64, check: Check<'_>) -> Result<f64, String> {
    let bs = 0.0_f64.max(-offset);
    let be = (b.len() as f64 / RATE as f64).min(a.len() as f64 / RATE as f64 - offset);
    let mut adjustments = Vec::new();
    for share in [0.15, 0.5, 0.85] {
        check()?;
        let t = bs + (be - bs - 3.0).max(0.0) * share;
        let duration = 3.0_f64.min(be - t);
        let q = bandpass(&extract(b, t, duration));
        let w = bandpass(&extract(a, t + offset - 0.15, duration + 0.3));
        let corr = normalized_correlation(&w, &q);
        let i = argmax(&corr);
        if corr[i] >= 0.3 {
            adjustments.push(i as f64 / RATE as f64 - 0.15);
        }
    }
    if adjustments.len() >= 2
        && adjustments
            .iter()
            .copied()
            .fold(f64::NEG_INFINITY, f64::max)
            - adjustments.iter().copied().fold(f64::INFINITY, f64::min)
            <= 0.002
    {
        Ok(offset + median(&adjustments))
    } else {
        Ok(offset)
    }
}

pub fn align(a: &[f32], b: &[f32], check: Check<'_>) -> Result<Alignment, String> {
    let fa = features(a, check)?;
    let fb = features(b, check)?;
    let mut offsets = vec![original_offset(a, b, &fa, &fb, check)?];
    for offset in hypotheses(&fa, &fb, check)? {
        if offsets.iter().all(|v| (v - offset).abs() >= 0.1) {
            offsets.push(offset);
        }
    }
    drop(fa);
    drop(fb);
    let mut accepted = Vec::new();
    for mut offset in offsets {
        let overlap = (b.len() as f64 / RATE as f64).min(a.len() as f64 / RATE as f64 - offset)
            - 0.0_f64.max(-offset);
        if overlap < 0.8 * a.len().min(b.len()) as f64 / RATE as f64 {
            continue;
        }
        offset = refine(a, b, offset, check)?;
        let ar = anchors(a, b, offset, check)?;
        let goods: Vec<_> = ar
            .iter()
            .filter(|a| good(a))
            .map(|a| a.lag_adjustment)
            .collect();
        if goods.len() < 6 {
            continue;
        }
        let median = median(&goods);
        if goods
            .iter()
            .filter(|&&lag| (lag - median).abs() <= 0.02000000001)
            .count()
            < 6
        {
            continue;
        }
        offset = refine(a, b, offset + median, check)?;
        let ar = anchors(a, b, offset, check)?;
        if gate(&ar) {
            let score = crate::audio_version_spectral::median(
                &ar.iter()
                    .map(|a| a.spectral_correlation)
                    .collect::<Vec<_>>(),
            );
            accepted.push((offset, score, ar));
        }
    }
    accepted.sort_by(|a, b| b.1.total_cmp(&a.1));
    if accepted.len() > 1 && accepted[0].1 - accepted[1].1 < 0.1 {
        return Ok(Alignment {
            decision: "ambiguous_offset",
            offset: None,
            anchors: Vec::new(),
        });
    }
    if let Some((offset, _, anchors)) = accepted.into_iter().next() {
        Ok(Alignment {
            decision: "aligned",
            offset: Some(offset),
            anchors,
        })
    } else {
        Ok(Alignment {
            decision: "alignment_unreliable",
            offset: None,
            anchors: Vec::new(),
        })
    }
}
