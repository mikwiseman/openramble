//! The last step before the engine sees the audio.

/// What the recognizer requires. Everything is resampled to this.
pub const ENGINE_SAMPLE_RATE: u32 = 16_000;

/// The shortest clip the engine may be handed, in samples.
///
/// 1.25 seconds. Not a quality judgement — the mel front-end produces NaNs on
/// input shorter than two frames, and those NaNs propagate into the decoder
/// rather than failing cleanly. A person who taps the key and says one syllable
/// is entitled to a transcript or an honest error, not a poisoned tensor.
///
/// The padding is silence at the end, so nothing that was said is displaced.
pub const MINIMUM_ENGINE_SAMPLES: usize = (ENGINE_SAMPLE_RATE as usize) * 5 / 4;

/// Pad a clip up to the engine's floor, if it falls short.
///
/// Returns the input untouched when it is already long enough, so the common
/// case allocates nothing.
pub fn prepare_for_engine(samples: &[f32]) -> std::borrow::Cow<'_, [f32]> {
    if samples.len() >= MINIMUM_ENGINE_SAMPLES {
        return std::borrow::Cow::Borrowed(samples);
    }
    let mut padded = Vec::with_capacity(MINIMUM_ENGINE_SAMPLES);
    padded.extend_from_slice(samples);
    padded.resize(MINIMUM_ENGINE_SAMPLES, 0.0);
    std::borrow::Cow::Owned(padded)
}

/// Fold interleaved channels down to mono by averaging.
///
/// Averaging rather than taking the first channel: on a stereo input where the
/// speaker is closer to one microphone, dropping a channel throws away half the
/// signal-to-noise the device collected.
pub fn to_mono(interleaved: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    let channels = channels as usize;
    interleaved
        .chunks(channels)
        .map(|frame| frame.iter().sum::<f32>() / frame.len() as f32)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_short_clip_is_padded_to_the_floor() {
        let padded = prepare_for_engine(&[0.5; 100]);
        assert_eq!(padded.len(), MINIMUM_ENGINE_SAMPLES);
        // What was said stays at the front; the padding is silence behind it.
        assert_eq!(padded[0], 0.5);
        assert_eq!(padded[99], 0.5);
        assert_eq!(padded[100], 0.0);
        assert_eq!(*padded.last().unwrap(), 0.0);
    }

    #[test]
    fn the_floor_is_one_and_a_quarter_seconds() {
        assert_eq!(MINIMUM_ENGINE_SAMPLES, 20_000);
    }

    #[test]
    fn a_long_enough_clip_is_passed_through_without_copying() {
        let samples = vec![0.25; MINIMUM_ENGINE_SAMPLES + 1];
        let prepared = prepare_for_engine(&samples);
        assert!(matches!(prepared, std::borrow::Cow::Borrowed(_)));
        assert_eq!(prepared.len(), samples.len());
    }

    #[test]
    fn an_empty_clip_becomes_silence_rather_than_a_nan_factory() {
        let padded = prepare_for_engine(&[]);
        assert_eq!(padded.len(), MINIMUM_ENGINE_SAMPLES);
        assert!(padded.iter().all(|&sample| sample == 0.0));
    }

    #[test]
    fn stereo_folds_down_by_averaging_both_channels() {
        // Averaging, not picking a channel: a speaker closer to one microphone
        // would otherwise lose half the signal the device collected.
        assert_eq!(to_mono(&[1.0, 0.0, 0.5, 0.5], 2), vec![0.5, 0.5]);
        assert_eq!(to_mono(&[1.0, 2.0, 3.0], 1), vec![1.0, 2.0, 3.0]);
    }
}
