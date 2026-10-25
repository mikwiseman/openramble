//! Any upload, decoded by ffmpeg into 16 kHz mono f32 in an unnamed file.
//!
//! ffmpeg reads the upload from its standard input, which is the upload's own
//! file rewound to the start: through `/dev/stdin` it is a seekable file, so an
//! m4a whose index sits at the end still decodes. ffmpeg may open only plain
//! files (`-protocol_whitelist file`) and only the container formats people
//! actually send (`-format_whitelist`), so a playlist that points at a URL is
//! refused rather than fetched. Its messages go nowhere: they can quote what
//! is inside the file.
//!
//! The decoded samples stream into a temporary file that has no name on disk
//! (`O_TMPFILE` on Linux), so nothing is left behind on any path, a crash
//! included. The 20 ms loudness envelope the planner needs is computed on the
//! way through, so the audio is never held in memory.

use std::fs::File;
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::process::{Command, Stdio};

use crate::plan::FRAME;

/// Samples per second of the decoded audio.
pub const RATE: u64 = 16_000;

/// The whole ffmpeg command line after the program name, on one line so the
/// network gate can see both whitelists.
const ARGS: &str = "-nostdin -v error -threads 1 -protocol_whitelist file -format_whitelist mov,ogg,matroska,wav,mp3,flac,aac,caf,aiff,asf,amr -i /dev/stdin -vn -ac 1 -ar 16000 -f f32le -";

pub fn argv() -> Vec<&'static str> {
    ARGS.split(' ').collect()
}

/// Decoded audio: `samples` f32le samples in `pcm`, and their envelope.
#[derive(Debug)]
pub struct Decoded {
    pub pcm: File,
    pub samples: u64,
    pub envelope: Vec<f32>,
}

#[derive(Debug)]
pub enum DecodeError {
    /// ffmpeg could not find audio in it.
    InvalidAudio,
    /// Longer than the caller allows.
    TooLong,
    /// The client went away.
    Cancelled,
    /// Our side failed: no ffmpeg, a full disk.
    Io(std::io::Error),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecodeError::InvalidAudio => write!(f, "no audio could be decoded"),
            DecodeError::TooLong => write!(f, "the audio is too long"),
            DecodeError::Cancelled => write!(f, "cancelled"),
            DecodeError::Io(error) => write!(f, "decoding failed: {error}"),
        }
    }
}

impl From<std::io::Error> for DecodeError {
    fn from(error: std::io::Error) -> Self {
        DecodeError::Io(error)
    }
}

/// Decode `input` into an unnamed file in `temp`, stopping once it passes
/// `max_s` seconds or `hung_up()` says the client has gone.
pub fn decode(
    mut input: File,
    temp: &Path,
    max_s: f64,
    hung_up: &dyn Fn() -> bool,
) -> Result<Decoded, DecodeError> {
    input.seek(SeekFrom::Start(0))?;
    let mut pcm = tempfile::tempfile_in(temp)?;
    let mut child = Command::new("ffmpeg")
        .args(argv())
        .stdin(Stdio::from(input))
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut stdout = child.stdout.take().expect("stdout is piped");
    let max_samples = (max_s * RATE as f64) as u64;
    let pumped = pump(&mut stdout, &mut pcm, max_samples, hung_up);
    drop(stdout);
    let (samples, envelope) = match pumped {
        Ok(done) => done,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
    };
    if !child.wait()?.success() || samples == 0 {
        return Err(DecodeError::InvalidAudio);
    }
    Ok(Decoded {
        pcm,
        samples,
        envelope,
    })
}

/// Copy f32le samples from `from` to `to`, replacing anything that is not a
/// finite number with silence and measuring the envelope on the way.
pub fn pump(
    from: &mut impl Read,
    to: &mut impl Write,
    max_samples: u64,
    hung_up: &dyn Fn() -> bool,
) -> Result<(u64, Vec<f32>), DecodeError> {
    let mut to = BufWriter::with_capacity(1 << 20, to);
    let mut buffer = vec![0u8; 1 << 16];
    let mut carried = 0;
    let mut samples = 0u64;
    let mut envelope = Envelope::default();
    loop {
        if hung_up() {
            return Err(DecodeError::Cancelled);
        }
        let read = match from.read(&mut buffer[carried..]) {
            Ok(0) => break,
            Ok(read) => read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.into()),
        };
        let filled = carried + read;
        let whole = filled / 4 * 4;
        for bytes in buffer[..whole].chunks_exact_mut(4) {
            let mut sample = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            if !sample.is_finite() {
                sample = 0.0;
                bytes.copy_from_slice(&sample.to_le_bytes());
            }
            envelope.push(sample);
        }
        samples += (whole / 4) as u64;
        if samples > max_samples {
            return Err(DecodeError::TooLong);
        }
        to.write_all(&buffer[..whole])?;
        buffer.copy_within(whole..filled, 0);
        carried = filled - whole;
    }
    to.flush()?;
    Ok((samples, envelope.finish()))
}

/// The RMS of every 20 ms frame, fed one sample at a time.
#[derive(Default)]
pub struct Envelope {
    frames: Vec<f32>,
    sum: f32,
    count: usize,
}

impl Envelope {
    pub fn push(&mut self, sample: f32) {
        self.sum += sample * sample;
        self.count += 1;
        if self.count == FRAME {
            self.close();
        }
    }

    fn close(&mut self) {
        self.frames.push((self.sum / self.count as f32).sqrt());
        self.sum = 0.0;
        self.count = 0;
    }

    /// The frames, the last one possibly shorter than 20 ms.
    pub fn finish(mut self) -> Vec<f32> {
        if self.count > 0 {
            self.close();
        }
        self.frames
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(samples: &[f32]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    /// Hands out the bytes a few at a time, in sizes that never line up with
    /// samples or frames.
    struct Dribble<'a> {
        bytes: &'a [u8],
        sizes: std::iter::Cycle<std::ops::RangeInclusive<usize>>,
    }

    impl Read for Dribble<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            let n = self
                .sizes
                .next()
                .unwrap()
                .min(buffer.len())
                .min(self.bytes.len());
            buffer[..n].copy_from_slice(&self.bytes[..n]);
            self.bytes = &self.bytes[n..];
            Ok(n)
        }
    }

    fn one_pass(samples: &[f32]) -> Vec<f32> {
        samples
            .chunks(FRAME)
            .map(|frame| (frame.iter().map(|x| x * x).sum::<f32>() / frame.len() as f32).sqrt())
            .collect()
    }

    #[test]
    fn the_command_line_allows_only_files_and_known_containers() {
        let argv = argv();
        let after = |flag: &str| argv[argv.iter().position(|a| *a == flag).unwrap() + 1];
        assert_eq!(after("-protocol_whitelist"), "file");
        assert_eq!(
            after("-format_whitelist"),
            "mov,ogg,matroska,wav,mp3,flac,aac,caf,aiff,asf,amr"
        );
        assert_eq!(after("-i"), "/dev/stdin");
        assert_eq!(after("-ar"), "16000");
        assert_eq!(after("-f"), "f32le");
        assert_eq!(argv.last(), Some(&"-"));
    }

    #[test]
    fn the_envelope_streamed_in_odd_pieces_equals_one_pass() {
        let samples: Vec<f32> = (0..FRAME * 7 + 123)
            .map(|i| ((i as f32) * 0.37).sin() * (i % 11) as f32 / 11.0)
            .collect();
        let input = bytes(&samples);
        for largest in 1..=17 {
            let mut reader = Dribble {
                bytes: &input,
                sizes: (1..=largest).cycle(),
            };
            let mut written = Vec::new();
            let (count, envelope) = pump(&mut reader, &mut written, u64::MAX, &|| false).unwrap();
            assert_eq!(count, samples.len() as u64);
            assert_eq!(written, input, "pieces up to {largest} bytes");
            assert_eq!(envelope, one_pass(&samples), "pieces up to {largest} bytes");
        }
    }

    #[test]
    fn numbers_that_are_not_audio_become_silence() {
        let input = bytes(&[0.5, f32::NAN, f32::INFINITY, -0.5]);
        let mut written = Vec::new();
        pump(&mut &input[..], &mut written, u64::MAX, &|| false).unwrap();
        assert_eq!(written, bytes(&[0.5, 0.0, 0.0, -0.5]));
    }

    #[test]
    fn the_length_cap_and_a_hang_up_stop_the_copy() {
        let input = bytes(&vec![0.1; 10_000]);
        assert!(matches!(
            pump(&mut &input[..], &mut Vec::new(), 9_999, &|| false),
            Err(DecodeError::TooLong)
        ));
        assert!(pump(&mut &input[..], &mut Vec::new(), 10_000, &|| false).is_ok());
        assert!(matches!(
            pump(&mut &input[..], &mut Vec::new(), u64::MAX, &|| true),
            Err(DecodeError::Cancelled)
        ));
    }
}
