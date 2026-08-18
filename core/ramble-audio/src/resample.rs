//! Getting whatever the device produced to the rate the engine requires.
//!
//! Devices offer 44.1 kHz, 48 kHz, sometimes 96 kHz; the recognizer takes 16 kHz
//! and nothing else. Feeding it audio at the wrong rate does not fail — it
//! transcribes a voice that sounds too fast or too slow, and the words come back
//! wrong for a reason no one can see.

use crate::prepare::ENGINE_SAMPLE_RATE;
use rubato::{
    Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction,
};

#[derive(Debug)]
pub enum ResampleError {
    Setup(String),
    Process(String),
}

impl std::fmt::Display for ResampleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResampleError::Setup(detail) => write!(f, "the resampler could not start: {detail}"),
            ResampleError::Process(detail) => {
                write!(f, "the audio could not be resampled: {detail}")
            }
        }
    }
}

impl std::error::Error for ResampleError {}

/// How many input samples are handed to the resampler at a time.
///
/// A whole take arrives at once, so this is an internal batching choice rather
/// than a latency budget; 1024 keeps the working set small without making the
/// per-chunk overhead matter.
const CHUNK: usize = 1024;

/// Convert mono samples to the engine's rate.
///
/// Returns the input unchanged when it is already at the right rate — the common
/// case on a device that offers 16 kHz directly, and worth not degrading through
/// a pointless filter pass.
pub fn resample(samples: &[f32], from_rate: u32) -> Result<Vec<f32>, ResampleError> {
    if from_rate == ENGINE_SAMPLE_RATE {
        return Ok(samples.to_vec());
    }
    if from_rate == 0 {
        return Err(ResampleError::Setup(
            "the device reported no sample rate".into(),
        ));
    }
    if samples.is_empty() {
        return Ok(Vec::new());
    }

    let ratio = ENGINE_SAMPLE_RATE as f64 / from_rate as f64;
    let parameters = SincInterpolationParameters {
        // 256 taps and a Blackman-Harris window: this runs once per take on a
        // buffer of seconds, so the cost is invisible and the anti-aliasing is
        // worth having. Downsampling 48 kHz to 16 kHz folds everything above
        // 8 kHz back into the speech band if the filter is sloppy.
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: SincInterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };

    let mut resampler = SincFixedIn::<f32>::new(ratio, 2.0, parameters, CHUNK, 1)
        .map_err(|error| ResampleError::Setup(error.to_string()))?;

    let mut output = Vec::with_capacity((samples.len() as f64 * ratio) as usize + CHUNK);
    let mut position = 0;
    while position < samples.len() {
        let end = (position + CHUNK).min(samples.len());
        let mut chunk = samples[position..end].to_vec();
        // The final chunk is padded so the resampler sees the fixed size it was
        // built for. The tail is silence, which costs a few milliseconds of
        // nothing at the end rather than truncating the last word.
        chunk.resize(CHUNK, 0.0);
        let processed = resampler
            .process(&[chunk], None)
            .map_err(|error| ResampleError::Process(error.to_string()))?;
        output.extend_from_slice(&processed[0]);
        position = end;
    }

    // Trim the tail the padding produced, so the result is the true length.
    let expected = (samples.len() as f64 * ratio).round() as usize;
    output.truncate(expected.min(output.len()));
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(rate: u32, seconds: f32, hz: f32) -> Vec<f32> {
        let count = (rate as f32 * seconds) as usize;
        (0..count)
            .map(|index| (index as f32 / rate as f32 * hz * std::f32::consts::TAU).sin() * 0.5)
            .collect()
    }

    #[test]
    fn audio_already_at_the_engine_rate_is_untouched() {
        let samples = tone(16_000, 0.1, 440.0);
        assert_eq!(resample(&samples, 16_000).unwrap(), samples);
    }

    #[test]
    fn forty_eight_kilohertz_becomes_sixteen() {
        let samples = tone(48_000, 1.0, 440.0);
        let converted = resample(&samples, 48_000).unwrap();
        // One second in, one second out.
        let difference = (converted.len() as i64 - 16_000).abs();
        assert!(difference < 50, "got {} samples", converted.len());
    }

    #[test]
    fn forty_four_point_one_kilohertz_becomes_sixteen() {
        let samples = tone(44_100, 1.0, 440.0);
        let converted = resample(&samples, 44_100).unwrap();
        let difference = (converted.len() as i64 - 16_000).abs();
        assert!(difference < 50, "got {} samples", converted.len());
    }

    /// The signal has to survive, not merely the sample count. A 440 Hz tone is
    /// well inside the speech band and must come out at the same pitch and a
    /// comparable level.
    #[test]
    fn the_tone_survives_the_conversion() {
        let converted = resample(&tone(48_000, 0.5, 440.0), 48_000).unwrap();
        // Ignore the filter's warm-up at the very start.
        let body = &converted[400..converted.len() - 400];

        let peak = body.iter().fold(0.0_f32, |peak, s| peak.max(s.abs()));
        assert!((0.4..0.6).contains(&peak), "peak was {peak}");

        // Count zero crossings: 440 Hz over this span, within a few percent.
        let crossings = body
            .windows(2)
            .filter(|pair| (pair[0] < 0.0) != (pair[1] < 0.0))
            .count();
        let seconds = body.len() as f32 / 16_000.0;
        let measured = crossings as f32 / 2.0 / seconds;
        assert!(
            (420.0..460.0).contains(&measured),
            "measured {measured} Hz, expected about 440"
        );
    }

    #[test]
    fn an_empty_recording_resamples_to_nothing() {
        assert!(resample(&[], 48_000).unwrap().is_empty());
    }

    /// Shorter than one internal chunk — the case the padding exists for.
    #[test]
    fn a_clip_shorter_than_a_chunk_still_converts() {
        let converted = resample(&tone(48_000, 0.01, 440.0), 48_000).unwrap();
        assert!(!converted.is_empty());
        assert!(converted.len() < 200, "got {}", converted.len());
    }

    #[test]
    fn a_device_reporting_no_rate_is_an_error_not_a_divide_by_zero() {
        assert!(matches!(resample(&[0.1], 0), Err(ResampleError::Setup(_))));
    }
}
