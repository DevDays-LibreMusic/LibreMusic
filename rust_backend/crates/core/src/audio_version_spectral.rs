//! Numeric primitives for the on-device port of the frozen audio comparator.
//! 16 kHz mono f32, scipy-compatible periodic Hann STFT, no padding.
use crate::media::hires::fft::Radix2Fft;

pub const RATE: usize = 16_000;
pub const HOP: usize = 160;
pub const FFT: usize = 1024;
pub const BANDS: usize = 32;
pub type Frame = [f64; BANDS];
pub type Check<'a> = &'a dyn Fn() -> Result<(), String>;

pub fn median(values: &[f64]) -> f64 {
    let mut copy = values.to_vec();
    copy.sort_by(f64::total_cmp);
    let n = copy.len();
    if n == 0 {
        return 0.0;
    }
    if n.is_multiple_of(2) {
        (copy[n / 2 - 1] + copy[n / 2]) / 2.0
    } else {
        copy[n / 2]
    }
}

pub fn frequencies() -> [f64; BANDS] {
    std::array::from_fn(|i| 80.0 * (7600.0_f64 / 80.0).powf((i as f64 + 0.5) / BANDS as f64))
}

pub fn features(samples: &[f32], check: Check<'_>) -> Result<Vec<Frame>, String> {
    if samples.len() < FFT {
        return Ok(Vec::new());
    }
    let edges: Vec<_> = (0..=BANDS)
        .map(|i| 80.0 * (7600.0_f64 / 80.0).powf(i as f64 / BANDS as f64))
        .collect();
    let bins: Vec<Vec<usize>> = (0..BANDS)
        .map(|band| {
            let mut bins: Vec<_> = (0..=FFT / 2)
                .filter(|&i| {
                    let hz = i as f64 * RATE as f64 / FFT as f64;
                    hz >= edges[band] && hz < edges[band + 1]
                })
                .collect();
            if bins.is_empty() {
                let hz = (edges[band] * edges[band + 1]).sqrt();
                bins.push((hz * FFT as f64 / RATE as f64).round() as usize);
            }
            bins
        })
        .collect();
    let fft = Radix2Fft::new(FFT);
    let window: Vec<_> = (0..FFT)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / FFT as f64).cos())
        .collect();
    let mut re = vec![0.0; FFT];
    let mut im = vec![0.0; FFT];
    let mut result = Vec::with_capacity((samples.len() - FFT) / HOP + 1);
    for (frame, start) in (0..=samples.len() - FFT).step_by(HOP).enumerate() {
        if frame % 128 == 0 {
            check()?;
        }
        for i in 0..FFT {
            re[i] = samples[start + i] as f64 * window[i] / (FFT as f64 / 2.0);
            im[i] = 0.0;
        }
        fft.transform(&mut re, &mut im);
        result.push(std::array::from_fn(|band| {
            let sum: f64 = bins[band]
                .iter()
                .map(|&i| re[i] * re[i] + im[i] * im[i])
                .sum();
            (sum / bins[band].len() as f64).max(1e-12).ln()
        }));
    }
    Ok(result)
}

/// scipy interp with float32 output, zero outside the complete recording.
pub fn extract(samples: &[f32], start: f64, duration: f64) -> Vec<f32> {
    let n = (duration * RATE as f64).round_ties_even().max(0.0) as usize;
    if samples.is_empty() {
        return vec![0.0; n];
    }
    (0..n)
        .map(|i| {
            let p = start * RATE as f64 + i as f64;
            if p < 0.0 || p > samples.len().saturating_sub(1) as f64 {
                return 0.0;
            }
            let index = p.floor() as usize;
            if index + 1 >= samples.len() {
                samples[index]
            } else {
                let fraction = p - index as f64;
                (samples[index] as f64 * (1.0 - fraction) + samples[index + 1] as f64 * fraction)
                    as f32
            }
        })
        .collect()
}

/// Valid cross-correlation through the shared radix-2 FFT, with bounded memory.
pub fn correlate(a: &[f64], b: &[f64]) -> Vec<f64> {
    if a.len() < b.len() || b.is_empty() {
        return Vec::new();
    }
    let n = (a.len() + b.len() - 1).next_power_of_two();
    let fft = Radix2Fft::new(n);
    let mut ar = vec![0.0; n];
    let mut ai = vec![0.0; n];
    let mut br = vec![0.0; n];
    let mut bi = vec![0.0; n];
    ar[..a.len()].copy_from_slice(a);
    br[..b.len()].copy_from_slice(b);
    fft.transform(&mut ar, &mut ai);
    fft.transform(&mut br, &mut bi);
    for i in 0..n {
        let real = ar[i] * br[i] + ai[i] * bi[i];
        let imag = ai[i] * br[i] - ar[i] * bi[i];
        ar[i] = real;
        ai[i] = -imag;
    }
    fft.transform(&mut ar, &mut ai);
    ar[..=a.len() - b.len()]
        .iter()
        .map(|x| x / n as f64)
        .collect()
}

pub fn normalized_correlation(a: &[f64], b: &[f64]) -> Vec<f64> {
    let mut dots = correlate(a, b);
    if dots.is_empty() {
        return dots;
    }
    let bpower = b.iter().map(|x| x * x).sum::<f64>();
    let mut power: f64 = a[..b.len()].iter().map(|x| x * x).sum();
    for (i, dot) in dots.iter_mut().enumerate() {
        if i > 0 {
            power += a[i + b.len() - 1].powi(2) - a[i - 1].powi(2);
        }
        *dot /= (power.max(0.0) * bpower).max(1e-15).sqrt();
    }
    dots
}

pub fn bandpass(samples: &[f32]) -> Vec<f64> {
    // scipy.signal.butter(3,[150,6000],btype='bandpass',fs=16000,output='sos').
    const SOS: [[f64; 6]; 3] = [
        [
            0.41798929627284526,
            0.8359785925456905,
            0.41798929627284526,
            1.0,
            1.044345057526626,
            0.48315526765812167,
        ],
        [
            1.0,
            0.0,
            -1.0,
            1.0,
            -0.5375624207869022,
            -0.3801140330494748,
        ],
        [1.0, -2.0, 1.0, 1.0, -1.9401047707915355, 0.943515656376499],
    ];
    let mut result: Vec<_> = samples.iter().map(|&x| x as f64).collect();
    for section in SOS {
        let mut z = [0.0, 0.0];
        for x in &mut result {
            let y = section[0] * *x + z[0];
            z[0] = section[1] * *x - section[4] * y + z[1];
            z[1] = section[2] * *x - section[5] * y;
            *x = y;
        }
    }
    result
}

/// scipy.ndimage.uniform_filter1d default reflect boundary and origin=0.
pub fn smooth(input: &[f64], size: usize) -> Vec<f64> {
    if input.is_empty() {
        return Vec::new();
    }
    let n = input.len() as isize;
    let value = |i: isize| {
        let mut index = i;
        while index < 0 || index >= n {
            index = if index < 0 {
                -index - 1
            } else {
                2 * n - index - 1
            };
        }
        input[index as usize]
    };
    let left = size as isize / 2;
    let mut sum: f64 = (-left..size as isize - left).map(value).sum();
    let mut out = Vec::with_capacity(input.len());
    for i in 0..n {
        if i > 0 {
            sum += value(i + size as isize - left - 1) - value(i - left - 1);
        }
        out.push(sum / size as f64);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fft_correlation_matches_direct() {
        let a = [1.0, 3.0, -2.0, 5.0, 0.0];
        let b = [2.0, -1.0, 0.5];
        let got = correlate(&a, &b);
        for (i, value) in got.iter().enumerate() {
            let expected: f64 = b.iter().enumerate().map(|(j, x)| x * a[i + j]).sum();
            assert!((value - expected).abs() < 1e-10);
        }
    }
    #[test]
    fn reflect_filter_and_fractional_extraction() {
        assert_eq!(smooth(&[1.0, 2.0, 3.0, 4.0], 2), vec![1.0, 1.5, 2.5, 3.5]);
        assert_eq!(
            extract(&[1.0, 3.0], 0.5 / RATE as f64, 1.0 / RATE as f64),
            vec![2.0]
        );
        assert_eq!(
            extract(&[1.0, 3.0], -1.0 / RATE as f64, 1.0 / RATE as f64),
            vec![0.0]
        );
    }
}

#[cfg(test)]
pub(crate) fn fixture_audio(seconds: usize) -> Vec<f32> {
    let mut state = 0x12345678_u32;
    (0..RATE * seconds)
        .map(|i| {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let t = i as f64 / RATE as f64;
            let env = 0.25 + 0.75 * (0.5 + 0.5 * (2.0 * std::f64::consts::PI * 0.47 * t).sin());
            (env * (0.2 * (2.0 * std::f64::consts::PI * (180.0 + 10.0 * t) * t).sin()
                + 0.08 * (2.0 * std::f64::consts::PI * (700.0 + 2.0 * t * t) * t).sin()
                + 0.14 * (state as f64 / 4294967296.0 - 0.5))) as f32
        })
        .collect()
}

#[cfg(test)]
mod golden_tests {
    use super::*;
    #[test]
    fn stft_and_filter_match_frozen_scipy() {
        let golden: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/audio_version_golden.json"))
                .unwrap();
        let samples = fixture_audio(2);
        let f = features(&samples, &|| Ok(())).unwrap();
        for frame in golden["features"].as_array().unwrap() {
            let index = frame["index"].as_u64().unwrap() as usize;
            for (j, want) in frame["values"].as_array().unwrap().iter().enumerate() {
                assert!(
                    (f[index][j] - want.as_f64().unwrap()).abs() < 0.0001,
                    "frame{index}band{j}: {} vs {want}",
                    f[index][j]
                );
            }
        }
        for (actual, expected) in bandpass(&samples[..32])
            .iter()
            .zip(golden["filter"].as_array().unwrap())
        {
            assert!((actual - expected.as_f64().unwrap()).abs() < 1e-7);
        }
    }
    #[test]
    fn feature_extraction_checks_cancellation_between_frames() {
        let calls = std::cell::Cell::new(0);
        let result = features(&fixture_audio(4), &|| {
            calls.set(calls.get() + 1);
            if calls.get() > 1 {
                Err("cancelled".into())
            } else {
                Ok(())
            }
        });
        assert_eq!(result.unwrap_err(), "cancelled");
    }
}
