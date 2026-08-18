//! Getting audio off the microphone.
//!
//! cpal touches the device; everything decidable lives in [`TakeBuffer`], which
//! knows nothing about audio hardware and can therefore be tested without any.
//! That split is deliberate: the containment rules below are the ones that stop
//! a forgotten hotkey from eating a machine's memory, and they should not only
//! be exercisable on a developer's laptop with a microphone plugged in.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex};

/// How long one dictation may run before capture stops on its own.
///
/// Ten minutes. Not a guess at how long people talk — it is the answer to a
/// hotkey that never came back up, which happens for real: a key handler dies, a
/// remote-desktop session swallows the release, the person walks away. Without a
/// ceiling that take grows at 64 KB a second until something gives, and the
/// something is usually the whole machine rather than this app. Ten minutes of
/// 16 kHz mono is about 38 MB, which is survivable, and no honest dictation ever
/// reaches it.
pub const MAXIMUM_TAKE_SECONDS: usize = 600;

/// A recording in progress.
///
/// Bounded by construction: once the ceiling is reached the buffer stops
/// accepting samples and remembers that it did, so the session can tell the
/// person their recording was cut short instead of silently handing back the
/// first ten minutes as though that were everything.
pub struct TakeBuffer {
    samples: Vec<f32>,
    limit: usize,
    truncated: bool,
}

impl TakeBuffer {
    pub fn new(sample_rate: u32) -> Self {
        TakeBuffer {
            samples: Vec::new(),
            limit: sample_rate as usize * MAXIMUM_TAKE_SECONDS,
            truncated: false,
        }
    }

    pub fn push(&mut self, incoming: &[f32]) {
        if self.samples.len() >= self.limit {
            self.truncated = true;
            return;
        }
        let room = self.limit - self.samples.len();
        if incoming.len() > room {
            self.samples.extend_from_slice(&incoming[..room]);
            self.truncated = true;
        } else {
            self.samples.extend_from_slice(incoming);
        }
    }

    pub fn samples(&self) -> &[f32] {
        &self.samples
    }

    /// Did the recording hit the ceiling? The person is told when it did.
    pub fn was_truncated(&self) -> bool {
        self.truncated
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    /// Hand back the recording and whether it hit the ceiling, together.
    ///
    /// Together on purpose. These were two calls once, and taking the samples
    /// reset the flag — so the truncation was read back as false every single
    /// time and nobody was ever told their recording had been cut short. One
    /// call cannot be made in the wrong order.
    pub fn take(&mut self) -> (Vec<f32>, bool) {
        let truncated = self.truncated;
        self.truncated = false;
        (std::mem::take(&mut self.samples), truncated)
    }
}

#[derive(Debug)]
pub enum CaptureError {
    NoDevice,
    Configuration(String),
    Start(String),
}

impl std::fmt::Display for CaptureError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // Said the way a person would understand it, not the way the audio
            // stack phrases it.
            CaptureError::NoDevice => write!(
                f,
                "No microphone is available. Check that one is connected and that \
                 OpenRamble is allowed to use it."
            ),
            CaptureError::Configuration(detail) => {
                write!(f, "The microphone could not be configured: {detail}")
            }
            CaptureError::Start(detail) => {
                write!(f, "The microphone could not be started: {detail}")
            }
        }
    }
}

impl std::error::Error for CaptureError {}

/// A live microphone stream writing into a shared buffer.
///
/// Dropping this stops the capture, which is what makes "the light goes out when
/// we are not listening" true by construction rather than by remembering to call
/// something.
pub struct Capture {
    _stream: cpal::Stream,
    buffer: Arc<Mutex<TakeBuffer>>,
    sample_rate: u32,
    channels: u16,
}

impl Capture {
    pub fn start() -> Result<Self, CaptureError> {
        let host = cpal::default_host();
        let device = host.default_input_device().ok_or(CaptureError::NoDevice)?;
        let config = device
            .default_input_config()
            .map_err(|error| CaptureError::Configuration(error.to_string()))?;

        let sample_rate = config.sample_rate();
        let channels = config.channels();
        let buffer = Arc::new(Mutex::new(TakeBuffer::new(sample_rate)));

        let sink = Arc::clone(&buffer);
        let stream_config: cpal::StreamConfig = config.into();
        let stream = device
            .build_input_stream(
                stream_config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    let mono = ramble_audio::prepare::to_mono(data, channels);
                    if let Ok(mut buffer) = sink.lock() {
                        buffer.push(&mono);
                    }
                },
                |error| {
                    // The device died mid-take. Nothing to recover here — the
                    // session notices the silence and says so.
                    eprintln!("microphone error: {error}");
                },
                None,
            )
            .map_err(|error| CaptureError::Configuration(error.to_string()))?;

        stream
            .play()
            .map_err(|error| CaptureError::Start(error.to_string()))?;

        Ok(Capture {
            _stream: stream,
            buffer,
            sample_rate,
            channels,
        })
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Stop and hand back what was recorded, at the engine's rate.
    pub fn finish(self) -> (Vec<f32>, bool) {
        self.buffer
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_accumulate_in_order() {
        let mut buffer = TakeBuffer::new(16_000);
        buffer.push(&[1.0, 2.0]);
        buffer.push(&[3.0]);
        assert_eq!(buffer.samples(), &[1.0, 2.0, 3.0]);
        assert!(!buffer.was_truncated());
    }

    /// The forgotten-hotkey case. Without the ceiling this grows until the
    /// machine, not the app, is what gives way.
    #[test]
    fn a_recording_that_never_ends_stops_at_the_ceiling() {
        let mut buffer = TakeBuffer::new(10);
        let limit = 10 * MAXIMUM_TAKE_SECONDS;
        buffer.push(&vec![0.5; limit + 1000]);

        assert_eq!(buffer.samples().len(), limit);
        assert!(
            buffer.was_truncated(),
            "the person must be told the recording was cut short"
        );
    }

    #[test]
    fn a_chunk_that_straddles_the_ceiling_keeps_what_fits() {
        let mut buffer = TakeBuffer::new(1);
        let limit = MAXIMUM_TAKE_SECONDS;
        buffer.push(&vec![0.5; limit - 2]);
        assert!(!buffer.was_truncated());

        buffer.push(&[0.5; 10]);
        assert_eq!(buffer.samples().len(), limit);
        assert!(buffer.was_truncated());
    }

    #[test]
    fn pushing_after_the_ceiling_changes_nothing_but_the_flag() {
        let mut buffer = TakeBuffer::new(1);
        buffer.push(&vec![0.5; MAXIMUM_TAKE_SECONDS + 5]);
        let length = buffer.samples().len();
        buffer.push(&[0.5; 100]);
        assert_eq!(buffer.samples().len(), length);
    }

    #[test]
    fn taking_the_recording_leaves_the_buffer_ready_for_the_next_one() {
        let mut buffer = TakeBuffer::new(16_000);
        buffer.push(&[1.0, 2.0]);
        let (samples, truncated) = buffer.take();
        assert_eq!(samples, vec![1.0, 2.0]);
        assert!(!truncated);
        assert!(buffer.is_empty());
        assert!(!buffer.was_truncated());
    }

    /// Taking the recording must report the truncation that happened, not the
    /// state of the buffer afterwards.
    ///
    /// This was wrong: taking the samples cleared the flag first, so every
    /// truncated recording was handed over as though it were complete and the
    /// ceiling might as well not have existed.
    #[test]
    fn a_truncated_recording_still_says_so_when_it_is_taken() {
        let mut buffer = TakeBuffer::new(1);
        buffer.push(&vec![0.5; MAXIMUM_TAKE_SECONDS + 10]);
        let (samples, truncated) = buffer.take();
        assert_eq!(samples.len(), MAXIMUM_TAKE_SECONDS);
        assert!(
            truncated,
            "the person must be told the recording was cut short"
        );
        // And the next take starts clean.
        assert!(!buffer.was_truncated());
    }

    #[test]
    fn the_ceiling_is_ten_minutes() {
        assert_eq!(MAXIMUM_TAKE_SECONDS, 600);
        // About 38 MB at 16 kHz mono float — survivable, and no honest
        // dictation reaches it.
        let bytes = 16_000 * MAXIMUM_TAKE_SECONDS * std::mem::size_of::<f32>();
        assert!(bytes < 40 * 1024 * 1024, "{bytes} bytes");
    }
}
