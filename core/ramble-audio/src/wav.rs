//! The recording as a file.
//!
//! Dictation history keeps the audio beside the transcript so a person can hear
//! what was actually said when the text is wrong. It is also what survives a
//! crash mid-take: a recording on disk can be recognized again, a recording only
//! in memory cannot.

use std::path::Path;

#[derive(Debug)]
pub enum WavError {
    Io(std::io::Error),
    Format(String),
}

impl std::fmt::Display for WavError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WavError::Io(error) => write!(f, "{error}"),
            WavError::Format(detail) => write!(f, "the recording could not be read: {detail}"),
        }
    }
}

impl std::error::Error for WavError {}

impl From<hound::Error> for WavError {
    fn from(error: hound::Error) -> Self {
        match error {
            hound::Error::IoError(io) => WavError::Io(io),
            other => WavError::Format(other.to_string()),
        }
    }
}

/// Write mono samples as 16-bit PCM.
///
/// Sixteen-bit rather than float: it halves the file, every audio player on
/// every platform opens it, and the engine's own input is quantized further
/// than this anyway.
pub fn write_wav(path: &Path, samples: &[f32], sample_rate: u32) -> Result<(), WavError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(WavError::Io)?;
    }
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec)?;
    for &sample in samples {
        // Clamped before scaling: a sample above 1.0 would wrap to a loud click
        // at the opposite polarity rather than merely clipping.
        let clamped = sample.clamp(-1.0, 1.0);
        writer.write_sample((clamped * i16::MAX as f32) as i16)?;
    }
    writer.finalize()?;
    Ok(())
}

/// Read a recording back as mono float samples and its rate.
pub fn read_wav(path: &Path) -> Result<(Vec<f32>, u32), WavError> {
    let mut reader = hound::WavReader::open(path)?;
    let spec = reader.spec();
    let samples: Result<Vec<f32>, hound::Error> = match spec.sample_format {
        hound::SampleFormat::Int => {
            let scale = 1.0 / (1_i64 << (spec.bits_per_sample - 1)) as f32;
            reader
                .samples::<i32>()
                .map(|sample| sample.map(|value| value as f32 * scale))
                .collect()
        }
        hound::SampleFormat::Float => reader.samples::<f32>().collect(),
    };
    let samples = samples?;
    Ok((
        crate::prepare::to_mono(&samples, spec.channels),
        spec.sample_rate,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recording_survives_the_round_trip() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("take.wav");
        let original: Vec<f32> = (0..1000)
            .map(|index| (index as f32 * 0.01).sin() * 0.8)
            .collect();

        write_wav(&path, &original, 16_000).unwrap();
        let (restored, rate) = read_wav(&path).unwrap();

        assert_eq!(rate, 16_000);
        assert_eq!(restored.len(), original.len());
        for (before, after) in original.iter().zip(&restored) {
            // 16-bit quantization is the only loss allowed here.
            assert!((before - after).abs() < 1e-4, "{before} vs {after}");
        }
    }

    /// A sample past full scale must clip, not wrap. Wrapping turns a loud
    /// moment into a click at the opposite polarity.
    #[test]
    fn samples_beyond_full_scale_clip_rather_than_wrap() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("hot.wav");
        write_wav(&path, &[2.0, -2.0, 0.0], 16_000).unwrap();
        let (restored, _) = read_wav(&path).unwrap();
        assert!(restored[0] > 0.99, "{}", restored[0]);
        assert!(restored[1] < -0.99, "{}", restored[1]);
    }

    #[test]
    fn the_directory_is_created_if_it_is_missing() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("nested/deeper/take.wav");
        write_wav(&path, &[0.0; 10], 16_000).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn an_empty_recording_is_still_a_valid_file() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("silent.wav");
        write_wav(&path, &[], 16_000).unwrap();
        let (samples, rate) = read_wav(&path).unwrap();
        assert!(samples.is_empty());
        assert_eq!(rate, 16_000);
    }

    #[test]
    fn a_file_that_is_not_a_recording_reports_a_format_error() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("not-audio.wav");
        std::fs::write(&path, b"this is not a wav file").unwrap();
        assert!(matches!(read_wav(&path), Err(WavError::Format(_))));
    }
}
